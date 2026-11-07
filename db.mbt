///|
/// moondb 数据库:Bitcask 风格的嵌入式 KV 引擎。
///
/// - 写路径:构造日志条目 → `Storage::append` → 更新内存 keydir
/// - 读路径:内存 keydir 直接命中(O(1))
/// - 打开:重放日志重建 keydir;CRC 损坏条目就地截断隔离并计入
///   `corrupted_entries`(WAL 语义:损坏点之前的完整条目全部保留)
/// - merge:按 keydir 重写紧凑日志,原子替换,回收空间
///
/// 引擎不做并发控制:v0 面向单线程嵌入场景(README 注明)。
/// 存储后端以 trait bound 泛型注入,零动态分发开销。
pub struct Db[S] {
  priv storage : S
  priv keydir : Map[String, Bytes]
  priv mut log_bytes : Int
  priv mut closed : Bool
  priv mut corrupted_entries : Int
  priv mut pending_since_sync : Int
}

///|
/// 打开数据库:重放 `storage` 中的日志恢复到最后一致状态。
///
/// 重放在首个损坏点停止(不完整尾部与 CRC 失败都算):损坏点之前的全部
/// 完整条目保留,损坏部分被截断,数量计入 `corrupted_entries`。
pub fn[S : Storage] Db::open(storage : S) -> Db[S] raise DbError {
  let data = storage.read_all()
  let db : Db[S] = {
    storage,
    keydir: {},
    log_bytes: 0,
    closed: false,
    corrupted_entries: 0,
    pending_since_sync: 0,
  }
  let mut offset = 0
  let mut keep = 0
  let mut replay_done = false
  while !replay_done && offset < data.length() {
    let step : Result[(Bool, Int), DbError] = try {
      let (entry, next) = decode_entry(data, offset)
      match entry {
        Some((key, value)) => {
          let k = bytes_to_string(key)
          match value {
            Some(v) => {
              db.keydir.set(k, v)
            }
            None => {
              // tombstone
              db.keydir.remove(k)
            }
          }
          Ok((true, next))
        }
        None => Ok((false, next))
      }
    } catch {
      corrupt => Err(corrupt)
    }
    match step {
      Ok((advance, next)) => {
        if advance {
          keep = next
        }
        offset = next
        if !advance {
          // 尾部不完整:重放结束,截断边界 = keep
          replay_done = true
        }
      }
      Err(_corrupt) => {
        // CRC 损坏:就地隔离,保留损坏点之前的完整数据
        replay_done = true
        db.corrupted_entries += 1
      }
    }
  }
  if keep < data.length() {
    storage.truncate(keep)
  }
  db.log_bytes = keep
  db.pending_since_sync = 0
  db
}

///|
/// 存储层失败的构造工厂。suberror 跨包只读,后端包(file/)通过本工厂
/// 构造错误,错误定义与构造始终留在引擎包内。
pub fn DbError::storage_failed(message : String) -> DbError {
  StorageFailed(message)
}

///|
/// 「引擎已关闭」错误的构造工厂(供后端包使用)。
pub fn DbError::closed() -> DbError {
  Closed
}

///|
fn bytes_to_string(b : Bytes) -> String {
  let buf = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    // 键按 UTF-16 码元写入(见 string_to_bytes),逐码元还原
    buf.write_char(b[i].to_int().to_char().unwrap())
  }
  buf.to_string()
}

///|
fn string_to_bytes(s : String) -> Bytes {
  let n = s.length()
  let fa : FixedArray[Byte] = FixedArray::make(n, byte_of(0))
  for i = 0; i < n; i = i + 1 {
    fa[i] = byte_of(s.get_char(i).unwrap().to_int() & 0xFF)
  }
  Bytes::from_array(fa)
}

///|
fn[S] Db::ensure_open(self : Db[S]) -> Unit raise DbError {
  guard !self.closed else { raise Closed }
}

///|
/// 写入或更新一个键。`sync=true` 时写后立刻持久化(强持久性需求时用,
/// 默认依赖 `close`/手动 `sync` 的批量语义)。
pub fn[S : Storage] Db::put(
  self : Db[S],
  key~ : String,
  value~ : Bytes,
  sync? : Bool = false,
) -> Unit raise DbError {
  self.ensure_open()
  guard key.length() > 0 else {
    raise InvalidArgument("key must not be empty")
  }
  let entry = encode_entry(string_to_bytes(key), Some(value))
  self.storage.append(entry)
  self.log_bytes += entry.length()
  self.pending_since_sync += 1
  self.keydir.set(key, value)
  if sync {
    self.storage.sync()
    self.pending_since_sync = 0
  }
}

///|
/// 读取一个键;不存在返回 None。
pub fn[S] Db::get(self : Db[S], key~ : String) -> Bytes? raise DbError {
  self.ensure_open()
  self.keydir.get(key)
}

///|
/// 删除一个键(写 tombstone)。返回删除前该键是否存在。
pub fn[S : Storage] Db::delete(
  self : Db[S],
  key~ : String,
  sync? : Bool = false,
) -> Bool raise DbError {
  self.ensure_open()
  guard key.length() > 0 else {
    raise InvalidArgument("key must not be empty")
  }
  let existed = self.keydir.contains(key)
  let entry = encode_entry(string_to_bytes(key), None)
  self.storage.append(entry)
  self.log_bytes += entry.length()
  self.pending_since_sync += 1
  self.keydir.remove(key)
  if sync {
    self.storage.sync()
    self.pending_since_sync = 0
  }
  existed
}

///|
/// 全部活跃键(按字典序)。
pub fn[S] Db::keys(self : Db[S]) -> Array[String] raise DbError {
  self.ensure_open()
  let out : Array[String] = []
  for key in self.keydir.keys() {
    out.push(key)
  }
  out.sort()
  out
}

///|
/// 遍历全部活跃键值(无序)。回调不应修改引擎。
pub fn[S] Db::fold(
  self : Db[S],
  f : (String, Bytes) -> Unit,
) -> Unit raise DbError {
  self.ensure_open()
  for pair in self.keydir.iter() {
    f(pair.0, pair.1)
  }
}

///|
/// 活跃键数量。
pub fn[S] Db::count(self : Db[S]) -> Int raise DbError {
  self.ensure_open()
  self.keydir.length()
}

///|
/// 当前日志字节数(merge 前后对比用于评估回收效果)。
pub fn[S] Db::log_bytes(self : Db[S]) -> Int {
  self.log_bytes
}

///|
/// 重放时被隔离的损坏条目数。
pub fn[S] Db::corrupted_entries(self : Db[S]) -> Int {
  self.corrupted_entries
}

///|
/// 自上次 sync 以来的写操作数(测试/监控用)。
pub fn[S] Db::pending_since_sync(self : Db[S]) -> Int {
  self.pending_since_sync
}

///|
/// 手动持久化。
pub fn[S : Storage] Db::sync(self : Db[S]) -> Unit raise DbError {
  self.ensure_open()
  self.storage.sync()
  self.pending_since_sync = 0
}

///|
/// 合并日志:把活跃条目重写成紧凑日志,原子替换全部内容。
///
/// 返回回收的字节数(旧日志大小 − 新日志大小)。内存 keydir 不变,
/// merge 过程中的可见性不受影响。`replace_all` 在 native 上走
/// 临时文件 + 原子 rename:任一时刻磁盘上是完整的旧日志或完整的新日志,
/// 合并途中崩溃不丢数据。
pub fn[S : Storage] Db::merge(self : Db[S]) -> Int raise DbError {
  self.ensure_open()
  let old_size = self.storage.size()
  // 构造紧凑日志:每个活跃键一条最新记录
  let compacted : Array[Byte] = []
  for key in self.keys() {
    match self.keydir.get(key) {
      Some(value) => {
        let entry = encode_entry(string_to_bytes(key), Some(value))
        for i = 0; i < entry.length(); i = i + 1 {
          compacted.push(entry[i])
        }
      }
      None => ()
    }
  }
  let new_size = compacted.length()
  let fa : FixedArray[Byte] = FixedArray::make(new_size, byte_of(0))
  for i = 0; i < new_size; i = i + 1 {
    fa[i] = compacted[i]
  }
  self.storage.replace_all(Bytes::from_array(fa))
  self.log_bytes = new_size
  self.pending_since_sync = 0
  old_size - new_size
}

///|
/// 持久化并关闭后端。之后任何操作抛 `Closed`。
pub fn[S : Storage] Db::close(self : Db[S]) -> Unit raise DbError {
  self.ensure_open()
  self.storage.sync()
  self.storage.close()
  self.closed = true
  self.pending_since_sync = 0
}
