// DO NOT EDIT —— 由 tools/src/codegen 从 contract/schema/ 生成。
// 改动请改 schema 并重跑 `npm run codegen`（红线 #6：契约即承重墙）。

library;

class DirectoryPhones {
  const DirectoryPhones({
    required this.items,
    required this.sourceUrl,
    required this.verifiedDate,
  });

  /// 当前来源完整公开电话目录；空数组仅表示已确认无条目，不表示请求失败。
  final List<DirectoryPhonesItems> items;
  /// 目录入口的绝对 HTTP(S) URL，供用户核对来源。
  final String sourceUrl;
  /// 作者最后核对公开来源的日历日 YYYY-MM-DD；不是抓取时间或学校对电话有效性的确认。
  final String verifiedDate;
}

class DirectoryPhonesItems {
  const DirectoryPhonesItems({
    required this.id,
    required this.name,
    required this.category,
    required this.phone,
    required this.sourceUrl,
    this.campus,
    this.address,
    this.note,
  });

  /// 学校和当前包内稳定的电话条目标识；同名服务或不同校区不得混合。
  final String id;
  /// 公开服务或办公室名称，纯文本。
  final String name;
  /// 学校提供的分类或所属单位，纯文本；客户端不预设学校类别。
  final String category;
  /// 可拨号码：3–15 位数字，可有前导加号；地区号由脚本明确补全，不含分机、USSD 或 URI。
  final String phone;
  /// 此号码的公开来源绝对 HTTP(S) URL，供核对；不是脚本网络授权。
  final String sourceUrl;
  /// 来源明确的校区，纯文本；省略表示来源未提供，不按号码猜测。
  final String? campus;
  /// 公开办公地点，纯文本；省略表示未知。
  final String? address;
  /// 公开服务范围、时间或分机说明，纯文本；省略表示未提供，不自动执行分机。
  final String? note;
}
