// moondb 黑盒测试:全部通过 MemStorage(纯 MoonBit),native/wasm 双后端可跑。
// 文件后端的端到端测试在 storage_file 的 native-only 测试文件里。

///|
fn new_db() -> @moondb.Db[@moondb.MemStorage] raise {
  @moondb.Db::open(@moondb.MemStorage::new())
}

///|
/// 模拟进程重启:把日志字节搬进一份新存储(相当于重新打开文件)。
/// `mangle` 允许测试在"落盘内容"上注入截断或损坏。
fn restart_mangled(
  storage : @moondb.MemStorage,
  mangle : (Bytes) -> Bytes,
) -> @moondb.MemStorage raise {
  let fresh = @moondb.MemStorage::new()
  fresh.append(mangle(storage.read_all()))
  fresh
}

///|
test "crc32 matches the IEEE standard check vector" {
  // "123456789" 的 CRC-32 标准值
  assert_eq(
    @moondb.crc32(b"123456789"),
    0xCBF43926U,
  )
}

///|
test "put and get round trip" {
  let db = new_db()
  db.put(key="alpha", value=b"one")
  db.put(key="beta", value=b"two")
  assert_eq(db.get(key="alpha"), Some(b"one"))
  assert_eq(db.get(key="beta"), Some(b"two"))
  assert_eq(db.get(key="gamma"), None)
  assert_eq(db.count(), 2)
  db.close()
}

///|
test "overwrite keeps the latest value" {
  let db = new_db()
  db.put(key="k", value=b"v1")
  db.put(key="k", value=b"v2")
  db.put(key="k", value=b"v3")
  assert_eq(db.get(key="k"), Some(b"v3"))
  assert_eq(db.count(), 1)
  db.close()
}

///|
test "delete writes a tombstone and reports existence" {
  let db = new_db()
  db.put(key="gone", value=b"x")
  assert_eq(db.delete(key="gone"), true)
  assert_eq(db.delete(key="gone"), false)
  assert_eq(db.get(key="gone"), None)
  assert_eq(db.count(), 0)
  db.close()
}

///|
test "keys are returned in lexicographic order" {
  let db = new_db()
  db.put(key="c", value=b"3")
  db.put(key="a", value=b"1")
  db.put(key="b", value=b"2")
  assert_eq(db.keys(), ["a", "b", "c"])
  // fold 覆盖全部键值
  let seen = Ref(0)
  db.fold(fn(_k, _v) { seen.val += 1 })
  assert_eq(seen.val, 3)
  db.close()
}

///|
test "reopening replays the log and restores state" {
  let storage = @moondb.MemStorage::new()
  let db = @moondb.Db::open(storage)
  db.put(key="keep", value=b"1")
  db.put(key="drop", value=b"2")
  db.put(key="drop", value=b"3")
  let _ = db.delete(key="drop")
  db.put(key="keep", value=b"updated")
  // 模拟进程重启:先取出落盘字节,再关引擎,重新打开"同一份文件"
  let fresh = restart_mangled(storage, raw => raw)
  db.close()
  let reopened = @moondb.Db::open(fresh)
  assert_eq(reopened.get(key="keep"), Some(b"updated"))
  assert_eq(reopened.get(key="drop"), None)
  assert_eq(reopened.count(), 1)
  assert_eq(reopened.corrupted_entries(), 0)
  reopened.close()
}

///|
test "truncated tail recovers to the last complete entry" {
  let storage = @moondb.MemStorage::new()
  let db = @moondb.Db::open(storage)
  db.put(key="first", value=b"aaaa")
  db.put(key="second", value=b"bbbb")
  // 模拟崩溃:日志在第二条记录中间被截断,并附带半条垃圾
  let kept = storage.size() - 3
  let recovered = @moondb.Db::open(restart_mangled(storage, raw => {
    let fa : FixedArray[Byte] = FixedArray::make(kept + 2, (0 : Int).to_byte())
    for i = 0; i < kept; i = i + 1 {
      fa[i] = raw[i]
    }
    fa[kept] = (0x01 : Int).to_byte()
    fa[kept + 1] = (0x02 : Int).to_byte()
    Bytes::from_array(fa)
  }))
  db.close()
  assert_eq(recovered.get(key="first"), Some(b"aaaa"))
  assert_eq(recovered.get(key="second"), None)
  assert_eq(recovered.corrupted_entries(), 0)
  recovered.close()
}

///|
test "corrupted mid-log entry is quarantined with prior data intact" {
  let storage = @moondb.MemStorage::new()
  let db = @moondb.Db::open(storage)
  db.put(key="good", value=b"payload")
  let split = db.log_bytes()
  db.put(key="doomed", value=b"xxxx")
  // 破坏第二条记录的 CRC(翻转其后 4 字节中的一个)
  let flip_at = split + 4
  let recovered = @moondb.Db::open(restart_mangled(storage, raw => {
    let fa : FixedArray[Byte] = FixedArray::make(raw.length(), (0 : Int).to_byte())
    for i = 0; i < raw.length(); i = i + 1 {
      fa[i] = raw[i]
    }
    fa[flip_at] = (0xFF : Int).to_byte()
    Bytes::from_array(fa)
  }))
  db.close()
  assert_eq(recovered.get(key="good"), Some(b"payload"))
  assert_eq(recovered.get(key="doomed"), None)
  assert_eq(recovered.corrupted_entries(), 1)
  recovered.close()
}

///|
test "merge reclaims space from overwritten and deleted keys" {
  let storage = @moondb.MemStorage::new()
  let db = @moondb.Db::open(storage)
  db.put(key="hot", value=b"v1")
  db.put(key="dead", value=b"soon")
  // 多轮覆盖制造冗余
  for i = 1; i <= 10; i = i + 1 {
    db.put(key="hot", value=b"value-version-\{i}")
  }
  let _ = db.delete(key="dead")
  let before = db.log_bytes()
  let reclaimed = db.merge()
  assert_true(reclaimed > 0)
  assert_eq(db.log_bytes(), before - reclaimed)
  // 合并后数据不变
  assert_eq(db.count(), 1)
  assert_eq(db.get(key="hot"), Some(b"value-version-10"))
  assert_eq(db.get(key="dead"), None)
  // 重开:紧凑日志重放结果一致
  let fresh = restart_mangled(storage, raw => raw)
  db.close()
  let reopened = @moondb.Db::open(fresh)
  assert_eq(reopened.count(), 1)
  assert_eq(reopened.get(key="hot"), Some(b"value-version-10"))
  reopened.close()
}

///|
test "invalid arguments are rejected without panics" {
  let db = new_db()
  let outcome = try {
    let _ = db.put(key="", value=b"x")
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("empty key should be rejected")
  }
  db.close()
  // 关闭后操作抛 Closed
  let outcome = try {
    let _ = db.get(key="x")
    Ok(())
  } catch {
    error => Err(error)
  }
  match outcome {
    Err(_) => ()
    Ok(_) => fail("operations after close should fail")
  }
}

///|
test "sync accounting tracks pending writes" {
  let db = new_db()
  assert_eq(db.pending_since_sync(), 0)
  db.put(key="a", value=b"1")
  db.put(key="b", value=b"2")
  assert_eq(db.pending_since_sync(), 2)
  db.sync()
  assert_eq(db.pending_since_sync(), 0)
  db.close()
}

///|
test "fuzz: random operations against a reference map stay consistent" {
  let db = new_db()
  let reference : Map[String, Bytes] = Map([])
  // 确定性 LCG,可复现
  let mut state = 0x5eed1234
  let next = fn(mask : Int) -> Int {
    state = state * 1103515245 + 12345
    if state < 0 {
      state = state & 0x7FFFFFFF
    }
    state & mask
  }
  let keys = ["k0", "k1", "k2", "k3", "k4", "k5", "k6", "k7"]
  for round = 0; round < 2000; round = round + 1 {
    let op = next(3)
    let key = keys[next(7)]
    if op == 0 {
      let value = b"v\{round}"
      db.put(key~, value~)
      reference.set(key, value)
    } else if op == 1 {
      let existed = db.delete(key~)
      let ref_existed = reference.contains(key)
      assert_eq(existed, ref_existed)
      reference.remove(key)
    } else {
      assert_eq(db.get(key~), reference.get(key))
    }
  }
  // 收尾一致性:全部键值与参考一致
  assert_eq(db.count(), reference.length())
  for pair in reference.iter() {
    assert_eq(db.get(key=pair.0), Some(pair.1))
  }
  db.close()
}
