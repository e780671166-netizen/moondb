///|
/// moondb-cli:嵌入式 KV 引擎的命令行演示(仅 native,文件落盘)。
///
/// 用法:
///
/// ```sh
/// moon run examples/moondb-cli --target native                 # 内置演示
/// moon run examples/moondb-cli --target native -- <db文件> put <key> <value>
/// moon run examples/moondb-cli --target native -- <db文件> get <key>
/// moon run examples/moondb-cli --target native -- <db文件> delete <key>
/// moon run examples/moondb-cli --target native -- <db文件> scan
/// moon run examples/moondb-cli --target native -- <db文件> merge
/// ```
fn main raise {
  let args = @env.args()
  if args.length() >= 4 && args[2] == "put" {
    run_put(path=args[1], key=args[3], value=if args.length() > 4 { args[4] } else { "" })
  } else if args.length() >= 4 && args[2] == "get" {
    run_get(path=args[1], key=args[3])
  } else if args.length() >= 4 && args[2] == "delete" {
    run_delete(path=args[1], key=args[3])
  } else if args.length() >= 3 && args[2] == "scan" {
    run_scan(path=args[1])
  } else if args.length() >= 3 && args[2] == "merge" {
    run_merge(path=args[1])
  } else {
    demo()
  }
}

///|
fn open_db(path~ : String) -> @moondb.Db[@moondb.FileStorage] raise {
  @moondb.Db::open(@moondb.FileStorage::new(path~))
}

///|
fn bytes_to_text(b : Bytes) -> String {
  let buf = StringBuilder()
  for i = 0; i < b.length(); i = i + 1 {
    buf.write_char(b[i].to_int().to_char().unwrap())
  }
  buf.to_string()
}

///|
fn run_put(path~ : String, key~ : String, value~ : String) -> Unit raise {
  let db = open_db(path~)
  db.put(key~, value=utf8_bytes(value))
  db.close()
  println("put " + key + " ok")
}

///|
fn run_get(path~ : String, key~ : String) -> Unit raise {
  let db = open_db(path~)
  match db.get(key~) {
    Some(value) => println(bytes_to_text(value))
    None => println("(nil)")
  }
  db.close()
}

///|
fn run_delete(path~ : String, key~ : String) -> Unit raise {
  let db = open_db(path~)
  let existed = db.delete(key~)
  db.close()
  println(if existed { "deleted " + key } else { "(nil)" })
}

///|
fn run_scan(path~ : String) -> Unit raise {
  let db = open_db(path~)
  for key in db.keys() {
    match db.get(key~) {
      Some(value) => println(key + " = " + bytes_to_text(value))
      None => ()
    }
  }
  db.close()
}

///|
fn run_merge(path~ : String) -> Unit raise {
  let db = open_db(path~)
  let before = db.log_bytes()
  let reclaimed = db.merge()
  db.close()
  println(
    "merge ok: " +
    before.to_string() +
    " -> " +
    (before - reclaimed).to_string() +
    " bytes (reclaimed " +
    reclaimed.to_string() +
    ")",
  )
}

///|
fn utf8_bytes(text : String) -> Bytes {
  // 值按 UTF-16 码元存(与键一致);CLI 场景即原样往返
  let n = text.length()
  let fa : FixedArray[Byte] = FixedArray::make(n, (0 : Int).to_byte())
  for i = 0; i < n; i = i + 1 {
    fa[i] = (text.get_char(i).unwrap().to_int() & 0xFF).to_byte()
  }
  Bytes::from_array(fa)
}

///|
/// 内置演示:写入 → 读回 → 覆盖 → 删除 → 合并 → 重开验证。
fn demo() -> Unit raise {
  let path = "moondb-demo.log"
  println("== moondb demo (" + path + ") ==")
  let db = open_db(path~)
  db.put(key="greeting", value=utf8_bytes("hello, moondb"))
  db.put(key="visitor", value=utf8_bytes("ada"))
  println("greeting = " + bytes_to_text(db.get(key="greeting").unwrap()))
  db.put(key="visitor", value=utf8_bytes("grace"))
  let _ = db.delete(key="greeting")
  println("keys after delete: " + db.keys().join(", "))
  let reclaimed = db.merge()
  println("merge reclaimed " + reclaimed.to_string() + " bytes")
  db.close()
  // 重开验证持久性
  let reopened = open_db(path~)
  println("reopened keys: " + reopened.keys().join(", "))
  println("visitor = " + bytes_to_text(reopened.get(key="visitor").unwrap()))
  reopened.close()
  println("== demo done ==")
}
