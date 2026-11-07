///|
/// moondb 的可恢复失败。所有损坏都返回结构化错误,不 panic。
/// (不派生 Debug:两代 moonc 的 derive 语法不兼容,而错误展示由
/// 各变体的字段自解释。)
pub suberror DbError {
  /// 日志负载 CRC 校验失败(位置附在消息里)。
  Corrupt(String)
  /// 存储层失败(文件打开/读写等)。
  StorageFailed(String)
  /// 引擎已关闭后仍被使用。
  Closed
  /// 参数非法(空键、超长键等)。
  InvalidArgument(String)
}

///|
/// tombstone 在 valuesz 字段中的编码(论文用 0xFFFFFFFF 表示删除记录)。
const TOMBSTONE_SIZE : UInt = 0xFFFFFFFFU

///|
const ENTRY_HEADER_SIZE : Int = 16

///|
/// 单条日志记录的编码(小端):
///
/// ```text
/// crc32(4) | tstamp(4) | ksz(4) | valuesz(4) | key(ksz) | value(valuesz)
/// ```
///
/// crc 覆盖 tstamp 之后的所有字节;valuesz = 0xFFFFFFFF 表示 tombstone
/// (此时无 value 字节)。tstamp 在 v0 恒为 0,保留字段供未来 MVCC 使用。
fn encode_entry(key : Bytes, value : Bytes?) -> Bytes {
  let ksz = key.length()
  let has_value = value is Some(_)
  let valuesz = match value {
    Some(v) => v.length().reinterpret_as_uint()
    None => TOMBSTONE_SIZE
  }
  let body_size = 12 + ksz + (if has_value { match value {
    Some(v) => v.length()
    None => 0
  } } else { 0 })
  let total = 4 + body_size
  let fa : FixedArray[Byte] = FixedArray::make(total, 0)
  // tstamp
  put_u32le(fa, 4, 0)
  // ksz
  put_u32le(fa, 8, ksz.reinterpret_as_uint())
  // valuesz
  put_u32le(fa, 12, valuesz)
  for i = 0; i < ksz; i = i + 1 {
    fa[16 + i] = key[i]
  }
  if has_value {
    match value {
      Some(v) =>
        for i = 0; i < v.length(); i = i + 1 {
          fa[16 + ksz + i] = v[i]
        }
      None => ()
    }
  }
  let checksum = crc32_range_fa(fa, 4, total)
  put_u32le(fa, 0, checksum)
  Bytes::from_array(fa)
}

///|
fn put_u32le(fa : FixedArray[Byte], off : Int, v : UInt) -> Unit {
  let x = v.reinterpret_as_int()
  fa[off] = (x & 0xFF).to_byte()
  fa[off + 1] = ((x >> 8) & 0xFF).to_byte()
  fa[off + 2] = ((x >> 16) & 0xFF).to_byte()
  fa[off + 3] = ((x >> 24) & 0xFF).to_byte()
}

///|
fn get_u32le(b : Bytes, off : Int) -> UInt {
  (b[off].to_uint())
    |
    (b[off + 1].to_uint() << 8)
    |
    (b[off + 2].to_uint() << 16)
    |
    (b[off + 3].to_uint() << 24)
}

///|
/// 解码一条日志记录。返回 (key, value?)——value 为 None 表示 tombstone。
/// 输入不足一个完整条目时返回 None(正常截断边界);CRC 不匹配抛 Corrupt。
fn decode_entry(
  data : Bytes,
  offset : Int,
) -> ((Bytes, Bytes?)?, Int) raise DbError {
  let total = data.length()
  if offset + ENTRY_HEADER_SIZE > total {
    return (None, total)
  }
  let checksum = get_u32le(data, offset)
  let ksz = get_u32le(data, offset + 8).reinterpret_as_int()
  let valuesz_raw = get_u32le(data, offset + 12)
  if ksz < 0 || ksz > total {
    raise Corrupt("entry at \{offset}: invalid key size \{ksz}")
  }
  let is_tombstone = valuesz_raw == TOMBSTONE_SIZE
  let valuesz = if is_tombstone { 0 } else { valuesz_raw.reinterpret_as_int() }
  if valuesz < 0 || valuesz > total {
    raise Corrupt("entry at \{offset}: invalid value size")
  }
  let body = 12 + ksz + valuesz
  let end = offset + 4 + body
  if end > total {
    // 尾部截断:不足一条完整记录
    return (None, total)
  }
  let actual = crc32_range(data, offset + 4, end)
  if actual != checksum {
    raise Corrupt("entry at \{offset}: crc mismatch")
  }
  let key = slice_bytes(data, offset + 16, ksz)
  let value : Bytes? = if is_tombstone {
    None
  } else {
    Some(slice_bytes(data, offset + 16 + ksz, valuesz))
  }
  (Some((key, value)), end)
}

///|
fn slice_bytes(b : Bytes, off : Int, len : Int) -> Bytes {
  let fa : FixedArray[Byte] = FixedArray::make(len, 0)
  for i = 0; i < len; i = i + 1 {
    fa[i] = b[off + i]
  }
  Bytes::from_array(fa)
}
