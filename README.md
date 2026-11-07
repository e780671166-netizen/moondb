# moondb

[English](#english) | [中文](#中文)

---

## 中文

**moondb** 是一个纯 MoonBit 实现的嵌入式 KV 存储引擎(Bitcask 风格),零 C 依赖,可在 native 与 Wasm-GC 双后端运行。

### 特性

- **Append-only 日志**:每条写入都追加到日志(16 字节头 + key + value),崩溃后重放恢复
- **CRC-32 校验**:逐条校验;损坏条目就地隔离,损坏点之前的数据零丢失(按 WAL 语义)
- **内存 keydir**:读路径 O(1),键值常驻内存
- **merge 回收**:把活跃条目重写为紧凑日志,临时文件 + 原子 rename 替换,合并途中崩溃不丢数据
- **tombstone 删除**:删除写入墓碑记录,重放时正确应用
- **结构化错误**:所有损坏与 IO 失败返回 `DbError`,绝不 panic

### 快速开始

```bash
# 运行测试(wasm-gc 后端,无需编译器工具链)
moon test

# native 后端(需要 C 编译器)
moon test --target native

# CLI 演示:put / get / delete / scan / merge
moon run examples/moondb-cli --target native
moon run examples/moondb-cli --target native -- mydb.log put greeting "hello"
moon run examples/moondb-cli --target native -- mydb.log get greeting
moon run examples/moondb-cli --target native -- mydb.log scan
```

### API 一览

```moonbit
// 内存后端(双后端可测)
let db = @moondb.Db::open(@moondb.MemStorage::new())
// 文件后端(native)
let db = @moondb.Db::open(@moondb.FileStorage::new(path="mydb.log"))

db.put(key="greeting", value=b"hello")   // 写入
db.get(key="greeting")                    // Some(b"hello") / None
db.delete(key="greeting")                 // 写 tombstone
db.keys()                                 // 字典序全键
let reclaimed = db.merge()                // 回收日志冗余
db.close()                                // 持久化并关闭
```

### 设计取舍(v0)

- **keydir 直接持有 value**(论文里是"文件位置 + 惰性读"):实现更简单,读路径相同,
  代价是内存占用与值总量成正比;merge 语义与 Bitcask 一致
- **单日志文件**:v0 未做文件轮转;merge 通过原子替换实现等价回收
- **tstamp 字段保留**(恒为 0),为未来 MVCC/批次原子写留位
- **单线程**使用模型,不做并发控制
- 文件 IO 通过 `native-stub` C 桥(约 200 行,仅 native 后端编译);wasm 后端使用内存存储,
  存储层抽象(`Storage` trait)保证引擎逻辑在两个后端完全一致

### 支持矩阵

| 能力 | native | wasm-gc / js |
|---|---|---|
| 内存引擎(MemStorage) | ✅ | ✅ |
| 文件引擎(FileStorage) | ✅ | ❌(无文件系统) |
| CLI | ✅ | ❌ |

### 参考来源

- Bitcask 论文:Riak,https://riak.com/assets/bitcask-intro.pdf
- 接口惯例参考:leveldb
- CRC-32:IEEE 802.3(多项式 0xEDB88320)

### 许可证

Apache-2.0。AI 辅助生成(ZCode),由 27 项测试(含崩溃恢复、损坏注入、
2000 轮随机对拍)与双后端回归验证。

---

## English

**moondb** is an embedded key-value storage engine (Bitcask-style) written in
pure MoonBit — zero C dependencies, runs on native and Wasm-GC.

### Features

- **Append-only log** with CRC-32 verification per record; corrupted entries
  are quarantined at recovery, preserving every complete record before the
  damage point (WAL semantics)
- **In-memory keydir**: O(1) reads
- **merge** rewrites live entries into a compact log and swaps it in via
  temp-file + atomic rename — crash-safe by construction
- **Tombstone deletes**, lexicographic `keys()`, structured `DbError` (no panics)

### Usage

```moonbit
let db = @moondb.Db::open(@moondb.MemStorage::new())   // or @moondb.FileStorage::new(path=...)
db.put(key="greeting", value=b"hello")
db.get(key="greeting") // Some(b"hello")
db.merge()             // reclaim log space
db.close()
```

See the Chinese section above for the full design notes, support matrix,
and CLI usage. License: Apache-2.0.
