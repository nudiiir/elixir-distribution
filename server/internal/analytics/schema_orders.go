package analytics

// Source « Commandes clients » (distribution, migration 0016) : une ligne par
// ligne de commande, vue v_customer_order_lines. Enregistrée après les
// sources historiques (le fichier suit schema.go dans l'ordre d'init).
func init() {
	register(&Source{
		Key: "customer_orders", LabelFR: "Commandes clients", LabelAR: "طلبيات الزبائن", Icon: "assignment",
		from: "v_customer_order_lines", DateField: "order_date",
		Fields: []Field{
			dim("order_date", "Date de commande", "تاريخ الطلبية", "date", "Temps"),
			dim("created_at", "Horodatage", "الوقت", "datetime", "Temps"),
			enumDim("status", "Statut", "الحالة", "Document",
				"new", "validated", "preparing", "ready", "shipping", "delivered", "invoiced", "cancelled"),
			enumDim("source", "Origine", "المصدر", "Document", "manual", "phone", "whatsapp", "rep", "web", "portal"),
			num("priority", "Priorité", "الأولوية", "Document"),
			dim("order_number", "N° commande", "رقم الطلبية", "string", "Document"),
			lookupDim("partner_id", "Client", "الزبون", "Partenaire", "/api/v1/partners?kind=customer"),
			dim("partner_name", "Client (nom)", "الزبون", "string", "Partenaire"),
			enumDim("client_type", "Type de client", "نوع الزبون", "Partenaire",
				"supermarket", "restaurant", "hotel", "wholesaler", "retailer", "individual", "other"),
			dim("wilaya", "Wilaya", "الولاية", "string", "Partenaire"),
			lookupDim("rep_user_id", "Commercial", "المندوب", "Partenaire", "/api/v1/users"),
			dim("rep_name", "Commercial (nom)", "المندوب", "string", "Partenaire"),
			lookupDim("route_id", "Tournée", "خط التوزيع", "Document", "/api/v1/delivery-routes"),
			dim("route_name", "Tournée (nom)", "خط التوزيع", "string", "Document"),
			lookupDim("warehouse_id", "Dépôt", "المستودع", "Document", "/api/v1/warehouses"),
			lookupDim("product_id", "Produit", "المنتج", "Produit", "/api/v1/products"),
			dim("product_name", "Produit (nom)", "المنتج", "string", "Produit"),
			lookupDim("category_id", "Catégorie", "الفئة", "Produit", "/api/v1/categories"),
			dim("category_name", "Catégorie (nom)", "الفئة", "string", "Produit"),
			dim("brand", "Marque", "العلامة التجارية", "string", "Produit"),
			dim("has_backorder", "Avec reliquat", "مع بقية", "bool", "Document"),
			qty("qty_ordered_milli", "Quantité commandée", "الكمية المطلوبة"),
			qty("qty_validated_milli", "Quantité validée", "الكمية المؤكدة"),
			qty("qty_delivered_milli", "Quantité livrée", "الكمية المسلمة"),
			qty("qty_backorder_milli", "Reliquat", "البقية"),
			qty("qty_free_milli", "Unités gratuites", "الوحدات المجانية"),
			num("discount_pct", "Remise % (x100)", "نسبة الخصم", "Montants"),
			money("unit_price", "Prix unitaire HT", "سعر الوحدة", ""),
			money("line_ht", "Montant HT", "المبلغ دون رسم", ""),
			money("line_ttc", "Montant TTC", "المبلغ الإجمالي", ""),
		},
		Named: []NamedMeasure{
			nm("orders_count", "Nombre de commandes", "عدد الطلبيات", "integer", "count", "COUNT(DISTINCT order_id)", ""),
			nm("amount_ttc", "Montant commandé TTC", "مبلغ الطلبيات", "currency", "centimes", "SUM(line_ttc)", ""),
			nm("amount_ht", "Montant commandé HT", "المبلغ دون رسم", "currency", "centimes", "SUM(line_ht)", ""),
			nm("qty_ordered", "Quantité commandée", "الكمية المطلوبة", "quantity", "milli", "SUM(qty_ordered_milli)", ""),
			nm("qty_delivered", "Quantité livrée", "الكمية المسلمة", "quantity", "milli", "SUM(qty_delivered_milli)", ""),
			nm("qty_backorder", "Reliquat", "البقية", "quantity", "milli", "SUM(qty_backorder_milli)", ""),
			nm("fill_rate", "Taux de service", "معدل التلبية", "percent", "percent",
				"1.0*SUM(qty_validated_milli)/NULLIF(SUM(qty_ordered_milli),0)", ""),
			nm("customers_count", "Clients distincts", "عدد الزبائن", "integer", "count", "COUNT(DISTINCT partner_id)", ""),
			nm("avg_order", "Commande moyenne TTC", "متوسط الطلبية", "currency", "centimes",
				"1.0*SUM(line_ttc)/NULLIF(COUNT(DISTINCT order_id),0)", ""),
			nm("lines_count", "Lignes", "الأسطر", "integer", "count", "COUNT(*)", ""),
		},
	})
}
