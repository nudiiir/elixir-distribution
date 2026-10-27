// Models of the CRM / messages API (docs/API_DISTRIBUTION.md §5 and §6).
// Amounts are integer centimes, quantities integer milli-units.

int _i(Object? v) => (v as num?)?.toInt() ?? 0;
int? _in(Object? v) => (v as num?)?.toInt();
double? _d(Object? v) => (v as num?)?.toDouble();
String _s(Object? v) => v == null ? '' : '$v';
String? _sn(Object? v) => v == null || '$v'.isEmpty ? null : '$v';
List<String> _ls(Object? v) => [for (final e in (v as List? ?? const [])) '$e'];
Map<String, dynamic> _m(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

// ---------------------------------------------------------------------------
// Labels (simple French words)
// ---------------------------------------------------------------------------

const clientTypeLabels = <String, String>{
  'supermarket': 'Supérette',
  'restaurant': 'Restaurant',
  'hotel': 'Hôtel',
  'wholesaler': 'Grossiste',
  'retailer': 'Détaillant',
  'individual': 'Particulier',
  'other': 'Autre',
};

const crmStatusLabels = <String, String>{
  'prospect': 'Prospect',
  'active': 'Actif',
  'dormant': 'Inactif',
  'blocked': 'Bloqué',
};

const partnerSourceLabels = <String, String>{
  'manual': 'Saisi au bureau',
  'web': 'Boutique en ligne',
  'import': 'Import',
  'rep': 'Commercial',
  'portal': 'Portail client',
};

const activityTypeLabels = <String, String>{
  'call': 'Appel',
  'visit': 'Visite',
  'note': 'Note',
  'whatsapp': 'WhatsApp',
  'sms': 'SMS',
  'email': 'E-mail',
  'meeting': 'Rendez-vous',
};

const taskTypeLabels = <String, String>{
  'call': 'Appeler',
  'visit': 'Visiter',
  'collect_payment': 'Encaisser',
  'follow_up': 'Relancer',
  'other': 'Autre',
};

const taskSourceLabels = <String, String>{
  'manual': 'Créée à la main',
  'auto_overdue': 'Auto : factures échues',
  'auto_inactive': 'Auto : client inactif',
  'auto_backorder': 'Auto : reliquat disponible',
};

const taskPriorityLabels = <int, String>{0: 'Normale', 1: 'Haute', 2: 'Urgente'};

const fileKindLabels = <String, String>{
  'license': 'Agrément / licence',
  'registre': 'Registre du commerce',
  'nif': 'Carte NIF',
  'nis': 'Carte NIS',
  'contract': 'Contrat',
  'id': 'Pièce d’identité',
  'other': 'Autre',
};

const messageChannelLabels = <String, String>{
  'whatsapp': 'WhatsApp',
  'sms': 'SMS',
  'email': 'E-mail',
};

const messageLangLabels = <String, String>{'fr': 'Français', 'ar': 'Arabe'};

const timelineKindLabels = <String, String>{
  'order': 'Commandes',
  'order_event': 'Suivi des commandes',
  'document': 'Documents',
  'payment': 'Paiements',
  'activity': 'Activités',
  'task': 'Tâches',
  'message': 'Messages',
};

/// The 58 wilayas (code, name). The name is what is stored on the client.
const wilayas = <(String, String)>[
  ('01', 'Adrar'), ('02', 'Chlef'), ('03', 'Laghouat'), ('04', 'Oum El Bouaghi'),
  ('05', 'Batna'), ('06', 'Béjaïa'), ('07', 'Biskra'), ('08', 'Béchar'),
  ('09', 'Blida'), ('10', 'Bouira'), ('11', 'Tamanrasset'), ('12', 'Tébessa'),
  ('13', 'Tlemcen'), ('14', 'Tiaret'), ('15', 'Tizi Ouzou'), ('16', 'Alger'),
  ('17', 'Djelfa'), ('18', 'Jijel'), ('19', 'Sétif'), ('20', 'Saïda'),
  ('21', 'Skikda'), ('22', 'Sidi Bel Abbès'), ('23', 'Annaba'), ('24', 'Guelma'),
  ('25', 'Constantine'), ('26', 'Médéa'), ('27', 'Mostaganem'), ('28', 'M’Sila'),
  ('29', 'Mascara'), ('30', 'Ouargla'), ('31', 'Oran'), ('32', 'El Bayadh'),
  ('33', 'Illizi'), ('34', 'Bordj Bou Arréridj'), ('35', 'Boumerdès'), ('36', 'El Tarf'),
  ('37', 'Tindouf'), ('38', 'Tissemsilt'), ('39', 'El Oued'), ('40', 'Khenchela'),
  ('41', 'Souk Ahras'), ('42', 'Tipaza'), ('43', 'Mila'), ('44', 'Aïn Defla'),
  ('45', 'Naâma'), ('46', 'Aïn Témouchent'), ('47', 'Ghardaïa'), ('48', 'Relizane'),
  ('49', 'Timimoun'), ('50', 'Bordj Badji Mokhtar'), ('51', 'Ouled Djellal'),
  ('52', 'Béni Abbès'), ('53', 'In Salah'), ('54', 'In Guezzam'), ('55', 'Touggourt'),
  ('56', 'Djanet'), ('57', 'El M’Ghair'), ('58', 'El Meniaa'),
];

/// « 16 · Alger » for a stored wilaya name (the name alone when unknown).
String wilayaLabel(String name) {
  if (name.isEmpty) return '';
  for (final (c, n) in wilayas) {
    if (n.toLowerCase() == name.toLowerCase() || c == name) return '$c · $n';
  }
  return name;
}

// ---------------------------------------------------------------------------
// Customer record
// ---------------------------------------------------------------------------

class CrmTag {
  CrmTag.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        colour = _s(j['colour']).isEmpty ? '#00CC99' : _s(j['colour']),
        partnersCount = _i(j['partners_count']);
  final String id;
  final String name;
  final String colour; // #RRGGBB
  final int partnersCount;
}

class PartnerContact {
  PartnerContact.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        partnerId = _s(j['partner_id']),
        name = _s(j['name']),
        role = _s(j['role']),
        phone = _s(j['phone']),
        whatsapp = _s(j['whatsapp']),
        email = _s(j['email']),
        isPrimary = j['is_primary'] == true,
        notes = _s(j['notes']);
  final String id;
  final String partnerId;
  final String name;
  final String role;
  final String phone;
  final String whatsapp;
  final String email;
  final bool isPrimary;
  final String notes;
}

class PartnerFile {
  PartnerFile.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        partnerId = _s(j['partner_id']),
        kind = _s(j['kind']).isEmpty ? 'other' : _s(j['kind']),
        name = _s(j['name']),
        mime = _s(j['mime']),
        size = _i(j['size']),
        expiresAt = _sn(j['expires_at']),
        expired = j['expired'] == true,
        notes = _s(j['notes']),
        createdAt = _s(j['created_at']);
  final String id;
  final String partnerId;
  final String kind;
  final String name;
  final String mime;
  final int size;
  final String? expiresAt;
  final bool expired;
  final String notes;
  final String createdAt;
}

class CrmPartnerCredit {
  CrmPartnerCredit.fromJson(Map<String, dynamic> j)
      : balance = _i(j['balance']),
        creditLimit = _i(j['credit_limit']),
        openOrdersTotal = _i(j['open_orders_total']),
        openOrdersCount = _i(j['open_orders_count']),
        availableCredit = _in(j['available_credit']),
        overdueAmount = _i(j['overdue_amount']),
        overdueCount = _i(j['overdue_count']),
        crmStatus = _s(j['crm_status']),
        paymentTermsDays = _in(j['payment_terms_days']);
  final int balance;
  final int creditLimit;
  final int openOrdersTotal;
  final int openOrdersCount;
  final int? availableCredit;
  final int overdueAmount;
  final int overdueCount;
  final String crmStatus;
  final int? paymentTermsDays;
}

class TopProduct {
  TopProduct.fromJson(Map<String, dynamic> j)
      : productId = _s(j['product_id']),
        name = _s(j['name']),
        qtyMilli = _i(j['qty_milli']),
        amount = _i(j['amount']);
  final String productId;
  final String name;
  final int qtyMilli;
  final int amount;
}

class PartnerKpis {
  PartnerKpis.fromJson(Map<String, dynamic> j)
      : turnover30 = _i(j['turnover_30d']),
        turnover90 = _i(j['turnover_90d']),
        turnover365 = _i(j['turnover_365d']),
        purchasesCount365 = _i(j['purchases_count_365d']),
        avgBasket = _i(j['avg_basket']),
        orderFrequencyDays = _d(j['order_frequency_days']),
        lastOrderDate = _sn(j['last_order_date']),
        daysSinceLastOrder = (j['days_since_last_order'] as num?)?.toInt() ?? -1,
        topProducts = [
          for (final e in (j['top_products'] as List? ?? const []))
            TopProduct.fromJson(_m(e))
        ],
        paymentDelayAvgDays = _d(j['payment_delay_avg_days']),
        balance = _i(j['balance']),
        creditLimit = _i(j['credit_limit']),
        creditUsagePct = _i(j['credit_usage_pct']),
        overdueAmount = _i(j['overdue_amount']),
        openOrdersCount = _i(j['open_orders_count']),
        openOrdersAmount = _i(j['open_orders_amount']),
        backorderLines = _i(j['backorder_lines']),
        backorderQtyMilli = _i(j['backorder_qty_milli']);
  final int turnover30;
  final int turnover90;
  final int turnover365;
  final int purchasesCount365;
  final int avgBasket;
  final double? orderFrequencyDays;
  final String? lastOrderDate;
  final int daysSinceLastOrder;
  final List<TopProduct> topProducts;
  final double? paymentDelayAvgDays;
  final int balance;
  final int creditLimit;
  final int creditUsagePct;
  final int overdueAmount;
  final int openOrdersCount;
  final int openOrdersAmount;
  final int backorderLines;
  final int backorderQtyMilli;
}

class TimelineItem {
  TimelineItem.fromJson(Map<String, dynamic> j)
      : kind = _s(j['kind']),
        id = _s(j['id']),
        at = _s(j['at']),
        title = _s(j['title']),
        detail = _s(j['detail']),
        amount = _in(j['amount']),
        refId = _sn(j['ref_id']),
        status = _s(j['status']),
        subType = _s(j['sub_type']),
        userName = _s(j['user_name']);
  final String kind;
  final String id;
  final String at;
  final String title;
  final String detail;
  final int? amount;
  final String? refId;
  final String status;
  final String subType;
  final String userName;
}

class TimelinePage {
  TimelinePage.fromJson(Map<String, dynamic> j)
      : items = [
          for (final e in (j['items'] as List? ?? const [])) TimelineItem.fromJson(_m(e))
        ],
        total = _i(j['total']),
        limit = _i(j['limit']),
        offset = _i(j['offset']);
  final List<TimelineItem> items;
  final int total;
  final int limit;
  final int offset;
}

// ---------------------------------------------------------------------------
// Activities and tasks
// ---------------------------------------------------------------------------

class CrmActivity {
  CrmActivity.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        partnerId = _s(j['partner_id']),
        partnerName = _s(j['partner_name']),
        type = _s(j['type']),
        outcome = _s(j['outcome']),
        summary = _s(j['summary']),
        at = _s(j['at']),
        durationMin = _i(j['duration_min']),
        userId = _sn(j['user_id']),
        userName = _s(j['user_name']),
        orderId = _sn(j['order_id']),
        orderNumber = _sn(j['order_number']),
        documentId = _sn(j['document_id']),
        latitude = _d(j['latitude']),
        longitude = _d(j['longitude']),
        nextAction = _s(j['next_action']);
  final String id;
  final String partnerId;
  final String partnerName;
  final String type;
  final String outcome;
  final String summary;
  final String at;
  final int durationMin;
  final String? userId;
  final String userName;
  final String? orderId;
  final String? orderNumber;
  final String? documentId;
  final double? latitude;
  final double? longitude;
  final String nextAction;
}

class CrmTask {
  CrmTask.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        title = _s(j['title']),
        description = _s(j['description']),
        partnerId = _sn(j['partner_id']),
        partnerName = _sn(j['partner_name']),
        partnerPhone = _sn(j['partner_phone']),
        orderId = _sn(j['order_id']),
        orderNumber = _sn(j['order_number']),
        assigneeId = _sn(j['assignee_id']),
        assigneeName = _s(j['assignee_name']),
        dueAt = _sn(j['due_at']),
        overdue = j['overdue'] == true,
        priority = _i(j['priority']),
        status = _s(j['status']).isEmpty ? 'open' : _s(j['status']),
        type = _s(j['type']).isEmpty ? 'other' : _s(j['type']),
        source = _s(j['source']).isEmpty ? 'manual' : _s(j['source']),
        completedAt = _sn(j['completed_at']),
        result = _s(j['result']),
        createdAt = _s(j['created_at']);
  final String id;
  final String title;
  final String description;
  final String? partnerId;
  final String? partnerName;
  final String? partnerPhone;
  final String? orderId;
  final String? orderNumber;
  final String? assigneeId;
  final String assigneeName;
  final String? dueAt;
  final bool overdue;
  final int priority;
  final String status; // open | done | cancelled
  final String type;
  final String source;
  final String? completedAt;
  final String result;
  final String createdAt;

  /// "YYYY-MM-DD" of the due date ('' = none).
  String get dueDate => dueAt == null || dueAt!.length < 10 ? '' : dueAt!.substring(0, 10);
  bool get isOpen => status == 'open';
}

class TaskSummary {
  TaskSummary.fromJson(Map<String, dynamic> j)
      : open = _i(j['open']),
        overdue = _i(j['overdue']),
        today = _i(j['today']),
        upcoming7d = _i(j['upcoming_7d']);
  const TaskSummary.empty()
      : open = 0,
        overdue = 0,
        today = 0,
        upcoming7d = 0;
  final int open;
  final int overdue;
  final int today;
  final int upcoming7d;
}

class TaskGenResult {
  TaskGenResult.fromJson(Map<String, dynamic> j)
      : created = _i(j['created']),
        byOverdue = _i(_m(j['by_source'])['auto_overdue']),
        byInactive = _i(_m(j['by_source'])['auto_inactive']),
        byBackorder = _i(_m(j['by_source'])['auto_backorder']),
        skipped = _i(j['skipped']),
        inactiveDays = _i(j['inactive_days']);
  final int created;
  final int byOverdue;
  final int byInactive;
  final int byBackorder;
  final int skipped;
  final int inactiveDays;
}

// ---------------------------------------------------------------------------
// Segments
// ---------------------------------------------------------------------------

class CrmSegment {
  CrmSegment.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        builtin = j['builtin'] == true,
        rules = _m(j['rules']);
  final String id;
  final String name;
  final bool builtin;

  /// SegmentRules as sent/received (builtin, days, min_pct, filters…).
  final Map<String, dynamic> rules;
}

class CustomerMetric {
  CustomerMetric.fromJson(Map<String, dynamic> j)
      : partnerId = _s(j['partner_id']),
        name = _s(j['name']),
        phone = _s(j['phone']),
        clientType = _s(j['client_type']),
        crmStatus = _s(j['crm_status']),
        wilaya = _s(j['wilaya']),
        repUserId = _sn(j['rep_user_id']),
        repName = _s(j['rep_name']),
        routeId = _sn(j['route_id']),
        createdAt = _s(j['created_at']),
        tagIds = _ls(j['tag_ids']),
        turnover = _i(j['turnover']),
        turnoverPrevious = _i(j['turnover_previous']),
        ordersCount = _i(j['orders_count']),
        lastOrderDate = _s(j['last_order_date']),
        daysSinceLastOrder = (j['days_since_last_order'] as num?)?.toInt() ?? -1,
        balance = _i(j['balance']),
        creditLimit = _i(j['credit_limit']),
        creditUsagePct = _i(j['credit_usage_pct']),
        overdueAmount = _i(j['overdue_amount']),
        overdueCount = _i(j['overdue_count']);
  final String partnerId;
  final String name;
  final String phone;
  final String clientType;
  final String crmStatus;
  final String wilaya;
  final String? repUserId;
  final String repName;
  final String? routeId;
  final String createdAt;
  final List<String> tagIds;
  final int turnover;
  final int turnoverPrevious;
  final int ordersCount;
  final String lastOrderDate;
  final int daysSinceLastOrder;
  final int balance;
  final int creditLimit;
  final int creditUsagePct;
  final int overdueAmount;
  final int overdueCount;
}

class SegmentResult {
  SegmentResult.fromJson(Map<String, dynamic> j)
      : items = [
          for (final e in (j['items'] as List? ?? const [])) CustomerMetric.fromJson(_m(e))
        ],
        count = _i(j['count']),
        periodFrom = _s(_m(j['period'])['from']),
        periodTo = _s(_m(j['period'])['to']),
        totalTurnover = _i(j['total_turnover']),
        totalBalance = _i(j['total_balance']);
  final List<CustomerMetric> items;
  final int count;
  final String periodFrom;
  final String periodTo;
  final int totalTurnover;
  final int totalBalance;
}

// ---------------------------------------------------------------------------
// Commerciaux
// ---------------------------------------------------------------------------

class RepTarget {
  RepTarget.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        userId = _s(j['user_id']),
        userName = _s(j['user_name']),
        month = _s(j['month']),
        salesTarget = _i(j['sales_target']),
        ordersTarget = _i(j['orders_target']),
        visitsTarget = _i(j['visits_target']),
        newCustomersTarget = _i(j['new_customers_target']),
        collectionsTarget = _i(j['collections_target']);
  final String id;
  final String userId;
  final String userName;
  final String month;
  final int salesTarget;
  final int ordersTarget;
  final int visitsTarget;
  final int newCustomersTarget;
  final int collectionsTarget;
}

class RepPerf {
  RepPerf.fromJson(Map<String, dynamic> j)
      : userId = _s(j['user_id']),
        name = _s(j['name']),
        month = _s(j['month']),
        sales = _i(j['sales']),
        ordersCount = _i(j['orders_count']),
        newCustomers = _i(j['new_customers']),
        visits = _i(j['visits']),
        calls = _i(j['calls']),
        collections = _i(j['collections']),
        customers = _i(j['customers']),
        targets = j['targets'] is Map ? RepTarget.fromJson(_m(j['targets'])) : null,
        achievement = {
          for (final e in _m(j['achievement_pct']).entries) e.key: _i(e.value)
        };
  final String userId;
  final String name;
  final String month;
  final int sales;
  final int ordersCount;
  final int newCustomers;
  final int visits;
  final int calls;
  final int collections;
  final int customers;
  final RepTarget? targets;

  /// sales / orders / visits / new_customers / collections → % (absent = no target).
  final Map<String, int> achievement;
}

/// A user that can be chosen as commercial / assignee.
class CrmUser {
  const CrmUser(this.id, this.name);
  final String id;
  final String name;
}

/// Delivery route template (« Tournée type », GET /delivery-routes) — only what the CRM screens need.
class CrmRoute {
  CrmRoute.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        name = _s(j['name']),
        wilayas = _ls(j['wilayas']),
        active = j['active'] != false,
        partnersCount = _i(j['partners_count']);
  final String id;
  final String name;
  final List<String> wilayas;
  final bool active;
  final int partnersCount;
}

// ---------------------------------------------------------------------------
// Messages
// ---------------------------------------------------------------------------

class MessageTemplate {
  MessageTemplate.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        code = _s(j['code']),
        channel = _s(j['channel']),
        lang = _s(j['lang']).isEmpty ? 'fr' : _s(j['lang']),
        name = _s(j['name']),
        subject = _s(j['subject']),
        body = _s(j['body']),
        active = j['active'] != false,
        isSystem = j['is_system'] == true,
        updatedAt = _s(j['updated_at']);
  final String id;
  final String code;
  final String channel;
  final String lang;
  final String name;
  final String subject;
  final String body;
  final bool active;
  final bool isSystem;
  final String updatedAt;

  String get title => name.isNotEmpty ? name : code;
}

class MessagePlaceholder {
  MessagePlaceholder.fromJson(Map<String, dynamic> j)
      : key = _s(j['key']),
        label = _s(j['label']);
  const MessagePlaceholder(this.key, this.label);
  final String key;
  final String label;
}

class RenderedMessage {
  RenderedMessage.fromJson(Map<String, dynamic> j)
      : channel = _s(j['channel']),
        templateCode = _s(j['template_code']),
        subject = _s(j['subject']),
        body = _s(j['body']),
        recipient = _s(j['recipient']),
        phoneIntl = _s(j['phone_intl']),
        waLink = _s(j['wa_link']),
        mailto = _s(j['mailto']),
        missing = _ls(j['missing']);
  final String channel;
  final String templateCode;
  final String subject;
  final String body;
  final String recipient;
  final String phoneIntl;
  final String waLink;
  final String mailto;
  final List<String> missing;
}

class MessageLog {
  MessageLog.fromJson(Map<String, dynamic> j)
      : id = _s(j['id']),
        partnerId = _sn(j['partner_id']),
        partnerName = _sn(j['partner_name']),
        orderId = _sn(j['order_id']),
        orderNumber = _sn(j['order_number']),
        channel = _s(j['channel']),
        templateCode = _s(j['template_code']),
        recipient = _s(j['recipient']),
        subject = _s(j['subject']),
        body = _s(j['body']),
        status = _s(j['status']),
        error = _s(j['error']),
        userName = _s(j['user_name']),
        createdAt = _s(j['created_at']);
  final String id;
  final String? partnerId;
  final String? partnerName;
  final String? orderId;
  final String? orderNumber;
  final String channel;
  final String templateCode;
  final String recipient;
  final String subject;
  final String body;
  final String status; // prepared | sent | failed
  final String error;
  final String userName;
  final String createdAt;
}
