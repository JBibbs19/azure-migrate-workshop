<%@ page contentType="application/json; charset=UTF-8" pageEncoding="UTF-8" session="false" trimDirectiveWhitespaces="true" errorPage="/WEB-INF/views/error.jsp" %>
<%@ include file="/WEB-INF/jspf/common.jspf" %>
<%
request.setCharacterEncoding("UTF-8");
response.setHeader("Cache-Control", "no-store");
response.setHeader("X-Content-Type-Options", "nosniff");
response.setHeader("X-Frame-Options", "DENY");
response.setHeader("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
String path = request.getRequestURI().substring(request.getContextPath().length());
String method = request.getMethod();
boolean known = path.equals("/") || path.equals("/api/health") || path.equals("/api/info") || path.equals("/api/ready") || path.equals("/api/orders");
if (!known) { response.setStatus(404); out.write("{\"error\":\"Not found\"}"); return; }
if (!method.equals("GET") && !(path.equals("/api/orders") && method.equals("POST"))) {
    response.setStatus(405); response.setHeader("Allow", path.equals("/api/orders") ? "GET, POST" : "GET");
    out.write("{\"error\":\"Method not allowed\"}"); return;
}
if (path.equals("/api/health")) {
    out.write("{\"status\":\"healthy\",\"server\":\"OnPrem-Linux-App\",\"timestamp\":" +
        json(java.time.Instant.now().toString()) + ",\"app\":\"Contoso Order Desk\"}"); return;
}
if (path.equals("/api/info")) {
    java.lang.Runtime runtime = java.lang.Runtime.getRuntime();
    String hostname = System.getenv("HOSTNAME");
    if (hostname == null) hostname = "OnPrem-Linux-App";
    out.write("{\"app\":\"Contoso Order Desk\",\"hostname\":" + json(hostname) +
        ",\"platform\":\"linux\",\"arch\":" + json(System.getProperty("os.arch")) +
        ",\"uptime\":" + (java.lang.management.ManagementFactory.getRuntimeMXBean().getUptime() / 1000) +
        ",\"memory\":{\"total\":" + runtime.totalMemory() + ",\"free\":" + runtime.freeMemory() +
        ",\"max\":" + runtime.maxMemory() + "},\"cpus\":" + runtime.availableProcessors() +
        ",\"javaVersion\":" + json(System.getProperty("java.version")) + ",\"environment\":\"on-premises\"}"); return;
}
if (method.equals("POST")) {
    String contentType = request.getContentType();
    if (contentType == null || !contentType.toLowerCase(java.util.Locale.ROOT).split(";", 2)[0].trim().equals("application/x-www-form-urlencoded")) {
        response.setStatus(415); out.write("{\"error\":\"Use application/x-www-form-urlencoded\"}"); return;
    }
    if (request.getContentLengthLong() > 4096) {
        response.setStatus(413); out.write("{\"error\":\"Request too large\"}"); return;
    }
    if (!sameOrigin(request)) { response.setStatus(403); out.write("{\"error\":\"Cross-site submission denied\"}"); return; }
    try {
        int orderId = createOrder(request);
        if ("1".equals(request.getParameter("returnToDesk"))) {
            response.setStatus(303); response.setHeader("Location", request.getContextPath() + "/?created=" + orderId);
        } else {
            response.setStatus(201); out.write("{\"orderId\":" + orderId + ",\"status\":\"created\"}");
        }
    } catch (DeskInputException e) {
        response.setStatus(400); out.write("{\"error\":" + json(e.getMessage()) + "}");
    } catch (Exception e) {
        application.log("Contoso Order Desk: create request could not complete; inspect SQL connectivity and schema locally.");
        response.setStatus(503); out.write("{\"error\":\"Order could not be saved. Check database readiness.\"}");
    }
    return;
}
if (path.equals("/api/ready")) {
    try (java.sql.Connection c = database().getConnection();
         java.sql.PreparedStatement s = statement(c, "SELECT 1"); java.sql.ResultSet r = s.executeQuery()) {
        if (!r.next()) throw new java.sql.SQLException();
        out.write("{\"status\":\"ready\",\"database\":\"reachable\",\"app\":\"Contoso Order Desk\"}");
    } catch (Exception e) {
        response.setStatus(503); out.write("{\"status\":\"not_ready\",\"database\":\"unavailable\",\"app\":\"Contoso Order Desk\"}");
    }
    return;
}
java.util.List<java.util.Map<String,String>> recent = null;
java.util.List<java.util.Map<String,String>> customerList = null;
long orderCount = 0, customerCount = 0;
try (java.sql.Connection c = database().getConnection()) {
    recent = orders(c); customerList = customers(c); orderCount = count(c, false); customerCount = count(c, true);
} catch (Exception e) {
    recent = null; customerList = null;
    response.setStatus(503);
    if (path.equals("/api/orders")) { out.write("{\"error\":\"Database unavailable\"}"); return; }
}
if (path.equals("/api/orders")) {
    out.write("{\"count\":" + orderCount + ",\"customerCount\":" + customerCount +
        ",\"orders\":" + rowsJson(recent) + ",\"customers\":" + rowsJson(customerList) + "}"); return;
}
response.setContentType("text/html; charset=UTF-8");
out.write("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
out.write("<title>Contoso Order Desk</title><style>body{font:16px system-ui,sans-serif;max-width:1050px;margin:32px auto;padding:0 20px;color:#152b40;background:#f5f7f9}h1{color:#005a9c}section{background:white;padding:20px;margin:20px 0;border:1px solid #ccd5dd;border-radius:6px}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:8px;border-bottom:1px solid #ddd}label{display:block;margin:12px 0}input,select,button{font:inherit;padding:6px}button{background:#005a9c;color:white;border:0;padding:10px 18px}a{color:#005a9c}.notice{color:#7d2500}.scroll{overflow-x:auto}</style></head><body>");
out.write("<header><p>TD SYNNEX | Cloud Enablement Services</p><h1>Contoso Order Desk</h1><p>Java / Tomcat application on OnPrem-Linux-App. Live orders from the existing ContosoApp SQL database.</p></header>");
out.write("<nav><a href=\"/api/health\">Runtime health</a> | <a href=\"/api/ready\">Database readiness</a> | <a href=\"/api/orders\">Orders API</a> | <a href=\"/api/info\">Runtime info</a></nav>");
if (recent == null) {
    out.write("<section class=\"notice\"><h2>Database unavailable</h2><p>The application is running, but the database is not ready. Check SQL login, host mapping, TCP 1433 and the runtime JNDI configuration. No order was created by this page.</p></section>");
} else {
    if (request.getParameter("created") != null && request.getParameter("created").matches("[0-9]{1,10}"))
        out.write("<p>Order " + html(request.getParameter("created")) + " was created.</p>");
    out.write("<section><h2>Order summary</h2><p><strong>" + orderCount + "</strong> orders | <strong>" + customerCount + "</strong> customers. Showing up to 20 recent orders; dates use SQL Server local time.</p><div class=\"scroll\"><table><thead><tr><th>Order</th><th>Customer</th><th>Product</th><th>Quantity</th><th>Price</th><th>Date</th></tr></thead><tbody>");
    for (java.util.Map<String,String> row : recent) {
        out.write("<tr>");
        for (String key : new String[]{"orderId", "customer", "productName", "quantity", "unitPrice", "orderDate"})
            out.write("<td>" + html(row.get(key)) + "</td>");
        out.write("</tr>");
    }
    out.write("</tbody></table></div></section><section><h2>Create a sample order</h2><p>This creates one real row. It never creates customers, tables or databases.</p>");
    if (customerList.isEmpty()) out.write("<p>No existing customers available. Have the lab administrator check the seeded database.</p>");
    else {
        out.write("<form method=\"post\" action=\"/api/orders\"><input type=\"hidden\" name=\"returnToDesk\" value=\"1\"><label>Existing customer <select name=\"customerId\" required>");
        for (java.util.Map<String,String> row : customerList)
            out.write("<option value=\"" + html(row.get("customerId")) + "\">" + html(row.get("name")) + " (#" + html(row.get("customerId")) + ")</option>");
        out.write("</select></label><label>Product <input name=\"productName\" maxlength=\"100\" value=\"Order Desk demo\" required></label><label>Quantity <input type=\"number\" name=\"quantity\" min=\"1\" max=\"10\" value=\"1\" required></label><label>Unit price <input type=\"number\" name=\"unitPrice\" min=\"0.01\" max=\"1000\" step=\"0.01\" value=\"9.99\" required></label><button type=\"submit\">Create sample order</button></form>");
    }
    out.write("</section>");
}
out.write("<footer><p>Local-network demo only: no user authentication, payment handling or production HTTPS. Do not expose it to the Internet.</p></footer></body></html>");
%>
