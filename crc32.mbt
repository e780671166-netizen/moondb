///|
/// moondb — 纯 MoonBit 嵌入式 KV 存储引擎(Bitcask 风格)。
///
/// 参考来源:Bitcask (Riak, https://riak.com/assets/bitcask-intro.pdf);
/// 接口惯例参考 leveldb。零 C 依赖(文件桥仅在 native 后端作为 stub 存在)。
///
/// v0 设计取舍(README 有完整说明):日志为 append-only 单文件,重放恢复;
/// keydir 常驻内存并直接持有最新 value(牺牲 O(1) 位置寻址换取实现简单,
/// merge 语义与 Bitcask 一致:重放去重 + 截断回收)。

///|
/// IEEE CRC-32(反射输入/输出,多项式 0xEDB88320),查表实现。
/// 每条日志记录携带其负载的 CRC,重放时校验以定位损坏尾部。
fn crc32_table() -> FixedArray[UInt] {
  let table : FixedArray[UInt] = FixedArray::make(256, 0U)
  for n = 0; n < 256; n = n + 1 {
    let mut c = n.reinterpret_as_uint()
    let mut bit = 0
    while bit < 8 {
      c = if (c & 1U) != 0U {
        0xEDB88320U ^ (c >> 1)
      } else {
        c >> 1
      }
      bit = bit + 1
    }
    table[n] = c
  }
  table
}

///|
/// 查表(模块加载后首次访问前已由 `crc32_table()` 构建)。
let crc32_table_singleton : FixedArray[UInt] = crc32_table()

///|
/// 计算字节序列的 CRC-32。
pub fn crc32(data : Bytes) -> UInt {
  let mut c = 0xFFFFFFFFU
  for i = 0; i < data.length(); i = i + 1 {
    let idx = ((c ^ data[i].to_uint()) & 0xFFU).reinterpret_as_int()
    c = crc32_table_singleton[idx] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFFU
}

///|
/// 计算字节切片 [start, end) 的 CRC-32(避免拷贝)。
fn crc32_range(data : Bytes, start : Int, end : Int) -> UInt {
  let mut c = 0xFFFFFFFFU
  for i = start; i < end; i = i + 1 {
    let idx = ((c ^ data[i].to_uint()) & 0xFFU).reinterpret_as_int()
    c = crc32_table_singleton[idx] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFFU
}

///|
/// FixedArray 版本的切片 CRC-32(编码路径直接对构建缓冲计算,零拷贝)。
fn crc32_range_fa(data : FixedArray[Byte], start : Int, end : Int) -> UInt {
  let mut c = 0xFFFFFFFFU
  for i = start; i < end; i = i + 1 {
    let idx = ((c ^ data[i].to_uint()) & 0xFFU).reinterpret_as_int()
    c = crc32_table_singleton[idx] ^ (c >> 8)
  }
  c ^ 0xFFFFFFFFU
}
