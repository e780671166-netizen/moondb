///|
/// FileStorage — native 后端的日志文件存储(仅 native target 编译)。
///
/// - `open` 追加读写:文件存在则保留内容(重放恢复语义)
/// - `replace_all` 走临时文件 + 原子 rename(C 桥实现)
/// - 线程模型与引擎一致:单线程使用
#borrow(path)
extern "C" fn moondb_file_open(path : String, path_units : Int) -> Int64 = "moondb_file_open"

///|
#borrow(data)
extern "C" fn moondb_file_append(
  handle : Int64,
  data : Bytes,
  data_len : Int,
) -> Int = "moondb_file_append"

///|
extern "C" fn moondb_file_size(handle : Int64) -> Int64 = "moondb_file_size"

///|
extern "C" fn moondb_file_read_all(handle : Int64, len : Int) -> Bytes? = "moondb_file_read_all"

///|
extern "C" fn moondb_file_truncate(
  handle : Int64,
  keep_bytes : Int,
) -> Int = "moondb_file_truncate"

///|
#borrow(data, path)
extern "C" fn moondb_file_replace_all(
  handle : Int64,
  data : Bytes,
  data_len : Int,
  path : String,
  path_units : Int,
) -> Int64 = "moondb_file_replace_all"

///|
extern "C" fn moondb_file_sync(handle : Int64) -> Unit = "moondb_file_sync"

///|
extern "C" fn moondb_file_close(handle : Int64) -> Unit = "moondb_file_close"

///|
/// 日志文件存储。`path` 为日志文件路径(追加写;不存在则创建)。
pub struct FileStorage {
  priv path : String
  priv handle : Ref[Int64]
  priv mut open : Bool
}

///|
/// 打开(或创建)日志文件。
pub fn FileStorage::new(path~ : String) -> FileStorage raise DbError {
  let handle = moondb_file_open(path, path.length())
  guard handle > 0L else {
    raise StorageFailed("cannot open log file: " + path)
  }
  { path, handle: Ref(handle), open: true, }
}

///|
fn FileStorage::ensure_open(self : FileStorage) -> Unit raise DbError {
  guard self.open else { raise Closed }
}

///|
pub impl Storage for FileStorage with append(self, data) {
  self.ensure_open()
  let code = moondb_file_append(self.handle.val, data, data.length())
  guard code == 0 else {
    raise StorageFailed("append failed")
  }
}

///|
pub impl Storage for FileStorage with read_all(self) {
  self.ensure_open()
  let size = moondb_file_size(self.handle.val)
  guard size >= 0L else {
    raise StorageFailed("size failed")
  }
  if size == 0L {
    return Bytes::from_array(FixedArray::make(0, (0 : Int).to_byte()))
  }
  let raw = moondb_file_read_all(self.handle.val, size.to_int())
  guard raw is Some(data) else {
    raise StorageFailed("read failed")
  }
  data
}

///|
pub impl Storage for FileStorage with truncate(self, keep_bytes) {
  self.ensure_open()
  let code = moondb_file_truncate(self.handle.val, keep_bytes)
  guard code == 0 else {
    raise StorageFailed("truncate failed")
  }
}

///|
pub impl Storage for FileStorage with replace_all(self, data) {
  self.ensure_open()
  let fresh = moondb_file_replace_all(
    self.handle.val,
    data,
    data.length(),
    self.path,
    self.path.length(),
  )
  guard fresh > 0L else {
    raise StorageFailed("replace_all failed")
  }
  self.handle.val = fresh
}

///|
pub impl Storage for FileStorage with size(self) {
  self.ensure_open()
  let size = moondb_file_size(self.handle.val)
  guard size >= 0L else {
    raise StorageFailed("size failed")
  }
  size.to_int()
}

///|
pub impl Storage for FileStorage with sync(self) {
  self.ensure_open()
  moondb_file_sync(self.handle.val)
}

///|
pub impl Storage for FileStorage with close(self) {
  self.ensure_open()
  moondb_file_close(self.handle.val)
  self.open = false
}

///|
pub extend FileStorage with Storage::{sync, close, replace_all, append, read_all, size, truncate}
