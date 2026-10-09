import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'crm_models.dart';
import 'models.dart';

export 'crm_models.dart';

/// Error of a CRM / messages call, with the whole JSON body (flags such as
/// `smtp_not_configured`, `log_id`).
class CrmApiException extends ApiException {
  CrmApiException(super.status, super.message,
      {super.needsApproval, super.action, super.amount, super.field, this.data = const {}});
  final Map<String, dynamic> data;

  bool get smtpNotConfigured => data['smtp_not_configured'] == true;
}

final _http = http.Client();

/// CRM + messages API (docs/API_DISTRIBUTION.md §5, §6), kept apart from the
/// shared client. Uses only the public surface of [ApiClient] (baseUrl,
/// token, approvalToken, onUnauthorized).
extension CrmApi on ApiClient {
  // ---- plumbing ----

  Map<String, String> get _crmHeaders {
    final approval = approvalToken;
    approvalToken = null;
    return {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
      'X-Approval': ?approval,
    };
  }

  Uri _crmUri(String path, [Map<String, String>? q]) =>
      Uri.parse('$baseUrl/api/v1$path')
          .replace(queryParameters: q == null || q.isEmpty ? null : q);

  dynamic _crmHandle(http.Response res) {
    Object? body;
    try {
      body = res.body.isEmpty ? null : jsonDecode(utf8.decode(res.bodyBytes));
    } catch (_) {
      body = null;
    }
    if (res.statusCode == 401 && token != null) onUnauthorized?.call();
    if (res.statusCode >= 400) {
      final m = body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
      throw CrmApiException(
        res.statusCode,
        m['error'] is String ? m['error'] as String : 'HTTP ${res.statusCode}',
        needsApproval: m['needs_approval'] == true,
        action: m['action'] as String?,
        amount: (m['amount'] as num?)?.toInt() ?? 0,
        field: m['field'] as String?,
        data: m,
      );
    }
    return body;
  }

  Future<dynamic> _cGet(String path, [Map<String, String>? q]) async =>
      _crmHandle(await _http.get(_crmUri(path, q), headers: _crmHeaders));

  Future<dynamic> _cPost(String path, [Object? body]) async => _crmHandle(await _http.post(
      _crmUri(path),
      headers: _crmHeaders,
      body: jsonEncode(body ?? const <String, dynamic>{})));

  Future<dynamic> _cPut(String path, Object body) async => _crmHandle(
      await _http.put(_crmUri(path), headers: _crmHeaders, body: jsonEncode(body)));

  Future<dynamic> _cDelete(String path) async =>
      _crmHandle(await _http.delete(_crmUri(path), headers: _crmHeaders));

  List<Map<String, dynamic>> _items(dynamic j) => [
        for (final e in ((j is Map ? j['items'] : null) as List? ?? const []))
          Map<String, dynamic>.from(e as Map)
      ];

  // ---- Clients (filters of GET /partners) ----

  Future<List<Partner>> crmPartners({
    String? q,
    String? kind,
    String? clientType,
    String? crmStatus,
    String? repUserId,
    String? routeId,
    String? wilaya,
    String? source,
    String? tagId,
    int limit = 500,
    int offset = 0,
  }) async {
    final j = await _cGet('/partners', {
      if (q != null && q.trim().isNotEmpty) 'q': q.trim(),
      'kind': ?kind,
      'client_type': ?clientType,
      'crm_status': ?crmStatus,
      'rep_user_id': ?repUserId,
      'route_id': ?routeId,
      'wilaya': ?wilaya,
      'source': ?source,
      'tag_id': ?tagId,
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
    });
    return [for (final e in _items(j)) Partner.fromJson(e)];
  }

  /// The historic fields a PUT /partners must always carry (they are replaced).
  static Map<String, dynamic> partnerBaseBody(Partner p) => {
        'kind': p.kind,
        'name': p.name,
        'phone': p.phone,
        'email': p.email,
        'address': p.address,
        'nif': p.nif,
        'nis': p.nis,
        'rc': p.rc,
        'ai': p.ai,
        'credit_limit': p.creditLimit,
        'notes': p.notes,
        'price_level': p.priceLevel,
        'min_shelf_days': p.minShelfDays,
        'over_receipt_pct': p.overReceiptPct,
        'active': p.active,
      };

  /// Changes a few CRM fields of a client (re-reads it to keep the others).
  Future<Partner> crmPatchPartner(String id, Map<String, dynamic> crmFields) async {
    final p = Partner.fromJson(
        Map<String, dynamic>.from(await _cGet('/partners/$id') as Map));
    final j = await _cPut('/partners/$id', {...partnerBaseBody(p), ...crmFields});
    return Partner.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<CrmPartnerCredit> crmPartnerCredit(String id) async =>
      CrmPartnerCredit.fromJson(Map<String, dynamic>.from(await _cGet('/partners/$id/credit') as Map));

  Future<PartnerKpis> crmPartnerKpis(String id) async =>
      PartnerKpis.fromJson(Map<String, dynamic>.from(await _cGet('/partners/$id/kpis') as Map));

  Future<TimelinePage> crmTimeline(String id,
      {int limit = 50, int offset = 0, List<String> kinds = const []}) async {
    final j = await _cGet('/partners/$id/timeline', {
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
      if (kinds.isNotEmpty) 'kinds': kinds.join(','),
    });
    return TimelinePage.fromJson(Map<String, dynamic>.from(j as Map));
  }

  // ---- Contacts ----

  Future<List<PartnerContact>> crmContacts(String partnerId) async =>
      [for (final e in _items(await _cGet('/partners/$partnerId/contacts'))) PartnerContact.fromJson(e)];

  Future<PartnerContact> crmSaveContact(String partnerId, Map<String, dynamic> data,
      {String? id}) async {
    final j = id == null
        ? await _cPost('/partners/$partnerId/contacts', data)
        : await _cPut('/partner-contacts/$id', data);
    return PartnerContact.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<void> crmDeleteContact(String id) => _cDelete('/partner-contacts/$id');

  // ---- Étiquettes ----

  Future<List<CrmTag>> crmTags() async =>
      [for (final e in _items(await _cGet('/tags'))) CrmTag.fromJson(e)];

  Future<CrmTag> crmSaveTag(String name, String colour, {String? id}) async {
    final body = {'name': name, 'colour': colour};
    final j = id == null ? await _cPost('/tags', body) : await _cPut('/tags/$id', body);
    return CrmTag.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<void> crmDeleteTag(String id) => _cDelete('/tags/$id');

  Future<Partner> crmSetPartnerTags(String partnerId, List<String> tagIds) async =>
      Partner.fromJson(Map<String, dynamic>.from(
          await _cPut('/partners/$partnerId/tags', {'tag_ids': tagIds}) as Map));

  // ---- Pièces (fichiers du client) ----

  Future<List<PartnerFile>> crmFiles(String partnerId) async =>
      [for (final e in _items(await _cGet('/partners/$partnerId/files'))) PartnerFile.fromJson(e)];

  Future<PartnerFile> crmUploadFile(String partnerId,
      {required String name,
      required String kind,
      required List<int> bytes,
      String? expiresAt,
      String notes = ''}) async {
    final res = await _http.post(
      _crmUri('/partners/$partnerId/files', {
        'name': name,
        'kind': kind,
        if (expiresAt != null && expiresAt.isNotEmpty) 'expires_at': expiresAt,
        if (notes.isNotEmpty) 'notes': notes,
      }),
      headers: {...authHeaders, 'Content-Type': 'application/octet-stream'},
      body: bytes,
    );
    return PartnerFile.fromJson(Map<String, dynamic>.from(_crmHandle(res) as Map));
  }

  Future<List<int>> crmFileBytes(String partnerId, String fileId) async {
    final res = await _http.get(_crmUri('/partners/$partnerId/files/$fileId'), headers: authHeaders);
    if (res.statusCode >= 400) _crmHandle(res);
    return res.bodyBytes;
  }

  Future<void> crmDeleteFile(String partnerId, String fileId) =>
      _cDelete('/partners/$partnerId/files/$fileId');

  // ---- Activités ----

  Future<List<CrmActivity>> crmActivities(
      {String? partnerId, String? userId, String? type, String? from, String? to, int limit = 100, int offset = 0}) async {
    final j = await _cGet('/crm/activities', {
      'partner_id': ?partnerId,
      'user_id': ?userId,
      'type': ?type,
      'from': ?from,
      'to': ?to,
      'limit': '$limit',
      if (offset > 0) 'offset': '$offset',
    });
    return [for (final e in _items(j)) CrmActivity.fromJson(e)];
  }

  Future<CrmActivity> crmSaveActivity(Map<String, dynamic> data, {String? id}) async {
    final j = id == null ? await _cPost('/crm/activities', data) : await _cPut('/crm/activities/$id', data);
    return CrmActivity.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<void> crmDeleteActivity(String id) => _cDelete('/crm/activities/$id');

  // ---- Tâches ----

  Future<List<CrmTask>> crmTasks({
    String? assigneeId,
    String status = 'open',
    String? partnerId,
    String? type,
    String? source,
    String? orderId,
    String? due,
    int limit = 500,
  }) async {
    final j = await _cGet('/crm/tasks', {
      'assignee_id': ?assigneeId,
      'status': status,
      'partner_id': ?partnerId,
      'type': ?type,
      'source': ?source,
      'order_id': ?orderId,
      'due': ?due,
      'limit': '$limit',
    });
    return [for (final e in _items(j)) CrmTask.fromJson(e)];
  }

  Future<TaskSummary> crmTaskSummary({String assigneeId = 'all'}) async => TaskSummary.fromJson(
      Map<String, dynamic>.from(await _cGet('/crm/tasks/summary', {'assignee_id': assigneeId}) as Map));

  Future<CrmTask> crmSaveTask(Map<String, dynamic> data, {String? id}) async {
    final j = id == null ? await _cPost('/crm/tasks', data) : await _cPut('/crm/tasks/$id', data);
    return CrmTask.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<CrmTask> crmCompleteTask(String id, {String result = ''}) async => CrmTask.fromJson(
      Map<String, dynamic>.from(
          await _cPost('/crm/tasks/$id/complete', {if (result.isNotEmpty) 'result': result}) as Map));

  Future<CrmTask> crmCancelTask(String id, {String result = ''}) async => CrmTask.fromJson(
      Map<String, dynamic>.from(
          await _cPost('/crm/tasks/$id/cancel', {if (result.isNotEmpty) 'result': result}) as Map));

  Future<TaskGenResult> crmGenerateTasks(
      {int? inactiveDays, bool overdue = true, bool inactive = true, bool backorder = true}) async {
    final j = await _cPost('/crm/tasks/generate', {
      'inactive_days': ?inactiveDays,
      'overdue': overdue,
      'inactive': inactive,
      'backorder': backorder,
    });
    return TaskGenResult.fromJson(Map<String, dynamic>.from(j as Map));
  }

  // ---- Segments ----

  Future<List<CrmSegment>> crmSegments() async =>
      [for (final e in _items(await _cGet('/crm/segments'))) CrmSegment.fromJson(e)];

  Future<CrmSegment> crmSaveSegment(String name, Map<String, dynamic> rules, {String? id}) async {
    final body = {'name': name, 'rules': rules};
    final j = id == null ? await _cPost('/crm/segments', body) : await _cPut('/crm/segments/$id', body);
    return CrmSegment.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<void> crmDeleteSegment(String id) => _cDelete('/crm/segments/$id');

  Future<SegmentResult> crmEvaluateRules(Map<String, dynamic> rules) async => SegmentResult.fromJson(
      Map<String, dynamic>.from(await _cPost('/crm/segments/evaluate', {'rules': rules}) as Map));

  Future<SegmentResult> crmEvaluateSegment(String id, {Map<String, String> overrides = const {}}) async =>
      SegmentResult.fromJson(Map<String, dynamic>.from(
          await _cGet('/crm/segments/$id/evaluate', overrides) as Map));

  // ---- Commerciaux ----

  Future<List<RepTarget>> crmRepTargets(String month) async =>
      [for (final e in _items(await _cGet('/crm/rep-targets', {'month': month}))) RepTarget.fromJson(e)];

  Future<RepTarget> crmSaveRepTarget(Map<String, dynamic> data) async =>
      RepTarget.fromJson(Map<String, dynamic>.from(await _cPut('/crm/rep-targets', data) as Map));

  Future<List<RepPerf>> crmRepPerformance(String month, {String? userId}) async => [
        for (final e in _items(await _cGet('/crm/reps/performance', {'month': month, 'user_id': ?userId})))
          RepPerf.fromJson(e)
      ];

  /// People who can be chosen as commercial / assignee. The full user list
  /// is admin-only: others get the users with a code caisse, the known
  /// commerciaux and themselves.
  Future<List<CrmUser>> crmUsers() async {
    final out = <String, String>{};
    try {
      final j = await _cGet('/users');
      for (final e in _items(j)) {
        if (e['active'] == false) continue;
        final full = (e['full_name'] as String?) ?? '';
        out['${e['id']}'] = full.isEmpty ? '${e['username']}' : full;
      }
    } catch (_) {
      try {
        for (final e in _items(await _cGet('/auth/pin-users'))) {
          final full = (e['full_name'] as String?) ?? '';
          out['${e['id']}'] = full.isEmpty ? '${e['username']}' : full;
        }
      } catch (_) {}
      try {
        final now = DateTime.now();
        final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
        for (final r in await crmRepPerformance(month)) {
          out.putIfAbsent(r.userId, () => r.name);
        }
      } catch (_) {}
    }
    final me = user;
    if (me != null) out.putIfAbsent(me.id, () => me.displayName);
    final list = [for (final e in out.entries) CrmUser(e.key, e.value)];
    list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return list;
  }

  /// Tournées types (lecture : deliveries.view | orders.view | crm.view).
  Future<List<CrmRoute>> crmRoutes() async =>
      [for (final e in _items(await _cGet('/delivery-routes'))) CrmRoute.fromJson(e)];

  // ---- Messages ----

  Future<List<MessageTemplate>> crmTemplates({String? code, String? channel, String? lang}) async => [
        for (final e in _items(await _cGet('/message-templates', {
          'code': ?code,
          'channel': ?channel,
          'lang': ?lang,
        })))
          MessageTemplate.fromJson(e)
      ];

  Future<MessageTemplate> crmSaveTemplate(Map<String, dynamic> data, {String? id}) async {
    final j = id == null ? await _cPost('/message-templates', data) : await _cPut('/message-templates/$id', data);
    return MessageTemplate.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<void> crmDeleteTemplate(String id) => _cDelete('/message-templates/$id');

  Future<List<MessagePlaceholder>> crmPlaceholders() async =>
      [for (final e in _items(await _cGet('/messages/placeholders'))) MessagePlaceholder.fromJson(e)];

  /// POST /messages/render — give [templateId], or [code] (+ channel, lang),
  /// or a free [body] (+ subject).
  Future<RenderedMessage> crmRender({
    String? templateId,
    String? code,
    String channel = 'whatsapp',
    String? lang,
    String? body,
    String? subject,
    String? partnerId,
    String? orderId,
    Map<String, String>? extra,
  }) async {
    final j = await _cPost('/messages/render', {
      'template_id': ?templateId,
      if (templateId == null && code != null) 'code': code,
      if (templateId == null && code == null) 'body': body ?? '',
      if (templateId == null && code == null && subject != null) 'subject': subject,
      'channel': channel,
      'lang': ?lang,
      'partner_id': ?partnerId,
      'order_id': ?orderId,
      if (extra != null && extra.isNotEmpty) 'extra': extra,
    });
    return RenderedMessage.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<MessageLog> crmLogMessage({
    String? partnerId,
    String? orderId,
    required String channel,
    String templateCode = '',
    String recipient = '',
    String subject = '',
    required String body,
    String status = 'prepared',
  }) async {
    final j = await _cPost('/messages/log', {
      'partner_id': ?partnerId,
      'order_id': ?orderId,
      'channel': channel,
      'template_code': templateCode,
      'recipient': recipient,
      'subject': subject,
      'body': body,
      'status': status,
    });
    return MessageLog.fromJson(Map<String, dynamic>.from(j as Map));
  }

  Future<List<MessageLog>> crmMessageLog({String? partnerId, String? orderId, String? channel, int limit = 100}) async => [
        for (final e in _items(await _cGet('/messages/log', {
          'partner_id': ?partnerId,
          'order_id': ?orderId,
          'channel': ?channel,
          'limit': '$limit',
        })))
          MessageLog.fromJson(e)
      ];

  Future<MessageLog> crmSendEmail({
    String? partnerId,
    String? orderId,
    String? to,
    required String subject,
    required String body,
    String templateCode = '',
  }) async {
    final j = await _cPost('/messages/send-email', {
      'partner_id': ?partnerId,
      'order_id': ?orderId,
      if (to != null && to.trim().isNotEmpty) 'to': to.trim(),
      'subject': subject,
      'body': body,
      'template_code': templateCode,
    });
    return MessageLog.fromJson(Map<String, dynamic>.from(j as Map));
  }
}
