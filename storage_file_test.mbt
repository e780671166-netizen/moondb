// FileStorage 端到端测试(仅 native:真实文件落盘、崩溃模拟、原子替换)。
// 临时文件写到系统临时目录,测试结束清理。

///|
fn temp_log_path(name~ : String) -> String {
  // 相对路径落在 moon test 的工作目录;正斜杠在 Windows CRT 下同样有效
  "moondb-test-" + name + ".log"
}

///|
fn remove_file(path~ : String) -> Unit {
  // 测试辅助:尽力删除;失败忽略(文件可能不存在)
  let _ = moondb_test_remove(path, path.length())
}

///|
#borrow(path)
extern "C" fn moondb_test_remove(path : String, path_units : Int) -> Int = "moondb_test_remove"

///|
test "file storage round trip and reopen" {
  let path = temp_log_path(name="roundtrip")
  remove_file(path~)
  let db = @moondb.Db::open(@moondb.FileStorage::new(path~))
  db.put(key="alpha", value=b"one")
  db.put(key="beta", value=b"two")
  db.put(key="alpha", value=b"one-updated")
  let _ = db.delete(key="beta")
  db.put(key="gamma", value=b"three")
  db.close()
  // 重开:重放日志恢复
  let reopened = @moondb.Db::open(@moondb.FileStorage::new(path~))
  assert_eq(reopened.count(), 2)
  assert_eq(reopened.get(key="alpha"), Some(b"one-updated"))
  assert_eq(reopened.get(key="beta"), None)
  assert_eq(reopened.get(key="gamma"), Some(b"three"))
  reopened.close()
  remove_file(path~)
}

///|
test "file storage merge is crash safe and reclaims space" {
  let path = temp_log_path(name="merge")
  remove_file(path~)
  let storage = @moondb.FileStorage::new(path~)
  let db = @moondb.Db::open(storage)
  db.put(key="hot", value=b"v0")
  for i = 1; i <= 20; i = i + 1 {
    db.put(key="hot", value=b"value-version-\{i}")
  }
  db.put(key="junk", value=b"to-be-deleted")
  let _ = db.delete(key="junk")
  let before = storage.size()
  let reclaimed = db.merge()
  assert_true(reclaimed > 0)
  assert_eq(before - reclaimed, storage.size())
  assert_eq(db.get(key="hot"), Some(b"value-version-20"))
  assert_eq(db.get(key="junk"), None)
  // replace_all 重开句柄:后续写仍落盘
  db.put(key="post-merge", value=b"ok")
  let fresh = @moondb.MemStorage::new()
  fresh.append(storage.read_all())
  db.close()
  let reopened = @moondb.Db::open(fresh)
  assert_eq(reopened.get(key="hot"), Some(b"value-version-20"))
  assert_eq(reopened.get(key="post-merge"), Some(b"ok"))
  assert_eq(reopened.count(), 2)
  reopened.close()
  remove_file(path~)
}

///|
test "file storage truncated tail recovers" {
  let path = temp_log_path(name="truncated")
  remove_file(path~)
  let storage = @moondb.FileStorage::new(path~)
  let db = @moondb.Db::open(storage)
  db.put(key="good", value=b"payload-1")
  db.put(key="second", value=b"payload-2")
  let full = storage.read_all()
  db.close()
  // 模拟崩溃:截掉最后 3 字节后重开
  let truncated : FixedArray[Byte] = FixedArray::make(full.length() - 3, (0 : Int).to_byte())
  for i = 0; i < full.length() - 3; i = i + 1 {
    truncated[i] = full[i]
  }
  let repaired = @moondb.FileStorage::new(path~)
  let _ = repaired.replace_all(Bytes::from_array(truncated))
  let _ = repaired.close()
  let recovered = @moondb.Db::open(@moondb.FileStorage::new(path~))
  assert_eq(recovered.get(key="good"), Some(b"payload-1"))
  assert_eq(recovered.get(key="second"), None)
  assert_eq(recovered.corrupted_entries(), 0)
  recovered.close()
  remove_file(path~)
}
