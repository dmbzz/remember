/// API 调用的**显式结果类型**。
///
/// 存在的意义：杜绝「把失败当成功 / 把没连上当没数据」的静默失败
/// （架构设计 §7.2「**禁止把没做当成做成了**」）。
///
/// 约定：调用方**必须先判 [ok]，再取 [data]**。
/// - `ok == true`：请求成功，[data] 可能为空集合/空串（**空 ≠ 失败**）；
/// - `ok == false`：请求失败，[error] 一定非空，且带可读原因（**含实际请求的 URL**）。
class ApiResult<T> {
  /// 成功时的数据（可能为空）；失败时为 `null`。
  final T? data;

  /// 失败原因（人类可读，含实际请求的 URL）；成功时为 `null`。
  final String? error;

  const ApiResult._(this.data, this.error);

  /// 成功（[data] 可以为空集合/空串，表示「请求成功但没有数据」）。
  const ApiResult.ok(T data) : this._(data, null);

  /// 失败（[error] 必带可读原因）。
  const ApiResult.failed(String error) : this._(null, error);

  /// 是否成功。
  bool get ok => error == null;
}
