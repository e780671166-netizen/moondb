///|
/// moondb 的字节编码辅助——由 Int 构造 Byte。
/// 不写字节字面量,统一走 `to_byte()`(规避部分 moonc 版本的字面量问题)。
fn byte_of(v : Int) -> Byte {
  v.to_byte()
}

///|
/// 存储后端抽象:把"追加日志文件"的平台细节隔离在 trait 后面。
///
/// - native 后端:`FileStorage`,C 桥直接操作 `FILE*`
/// - wasm/内存:`MemStorage`,纯内存实现
///
/// 方法通过内部 `Ref` 状态实现可变语义,因此 trait 的 `self` 保持不可变。
/// 所有失败都折叠为 `DbError::StorageFailed`。
pub trait Storage {
  /// 追加字节到日志末尾。
  append(Self, data : Bytes) -> Unit raise DbError
  /// 读取日志全部内容(重放用)。
  read_all(Self) -> Bytes raise DbError
  /// 截断日志,仅保留前 `keep_bytes` 字节(重放后隔离损坏尾部)。
  truncate(Self, keep_bytes : Int) -> Unit raise DbError
  /// 原子替换全部内容(merge 用:native 实现走临时文件 + rename,
  /// 任一时刻磁盘上是完整的旧日志或完整的新日志)。
  replace_all(Self, data : Bytes) -> Unit raise DbError
  /// 当前日志字节数。
  size(Self) -> Int raise DbError
  /// 持久化(内存实现为 no-op)。
  sync(Self) -> Unit raise DbError
  /// 关闭后端;之后任何操作抛 `Closed`。
  close(Self) -> Unit raise DbError
}

///|
/// 内存存储:双后端测试与 wasm 目标使用的实现。
/// 数据保存在 `Ref` 内,语义与文件后端一致(append 追加、truncate 截断)。
pub struct MemStorage {
  priv data : @ref.Ref[Array[Byte]]
  priv mut open : Bool
}

///|
/// 创建空的内存存储。
pub fn MemStorage::new() -> MemStorage {
  { data: Ref([]), open: true, }
}

///|
pub extend MemStorage with Storage::{sync, close, append, read_all, size, truncate, replace_all}

///|
pub impl Storage for MemStorage with append(self, data) {
  guard self.open else { raise Closed }
  for i = 0; i < data.length(); i = i + 1 {
    self.data.val.push(data[i])
  }
}

///|
pub impl Storage for MemStorage with read_all(self) {
  guard self.open else { raise Closed }
  let arr = self.data.val
  let fa : FixedArray[Byte] = FixedArray::make(arr.length(), byte_of(0))
  for i = 0; i < arr.length(); i = i + 1 {
    fa[i] = arr[i]
  }
  Bytes::from_array(fa)
}

///|
pub impl Storage for MemStorage with truncate(self, keep_bytes) {
  guard self.open else { raise Closed }
  guard keep_bytes >= 0 && keep_bytes <= self.data.val.length()
  else {
    raise StorageFailed("truncate out of range")
  }
  self.data.val.truncate(keep_bytes)
}

///|
pub impl Storage for MemStorage with replace_all(self, data) {
  guard self.open else { raise Closed }
  let fresh : Array[Byte] = []
  for i = 0; i < data.length(); i = i + 1 {
    fresh.push(data[i])
  }
  self.data.val = fresh
}

///|
pub impl Storage for MemStorage with size(self) {
  guard self.open else { raise Closed }
  self.data.val.length()
}

///|
pub impl Storage for MemStorage with sync(self) {
  guard self.open else { raise Closed }
}

///|
pub impl Storage for MemStorage with close(self) {
  guard self.open else { raise Closed }
  self.open = false
}
