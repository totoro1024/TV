package com.fongmi.android.tv.sync;

import org.json.JSONArray;
import org.json.JSONObject;
import java.io.IOException;
import java.net.InetAddress;
import java.net.Proxy;
import java.net.UnknownHostException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;
import okhttp3.*;

/** UC 官方扫码授权。只对受影响的 CAS 主机使用 HTTPS DNS，保留标准 TLS 验证。 */
public final class UcLoginClient {
    private static final String CAS = "api.open.uc.cn";
    private static final String UA = "Mozilla/5.0 (Linux; U; Android 13; zh-CN) AppleWebKit/537.36 (KHTML, like Gecko) UCBrowser/15.5.8.1238 Mobile Safari/537.36";
    private final OkHttpClient client;
    private final String requestID = Long.toString(System.currentTimeMillis());
    public UcLoginClient() {
        OkHttpClient resolver = new OkHttpClient.Builder().proxy(Proxy.NO_PROXY).callTimeout(12,TimeUnit.SECONDS).build();
        client = resolver.newBuilder().followRedirects(false).dns(host -> {
            if (!host.equals(CAS)) return Dns.SYSTEM.lookup(host);
            Request request = new Request.Builder().url("https://cloudflare-dns.com/dns-query?name=" + CAS + "&type=A").header("Accept","application/dns-json").build();
            try (Response reply = resolver.newCall(request).execute()) {
                if (!reply.isSuccessful() || reply.body() == null) throw new IOException();
                JSONArray rows = new JSONObject(reply.body().string()).optJSONArray("Answer");
                List<InetAddress> result = new ArrayList<>();
                if (rows != null) for (int i=0;i<rows.length();i++) {
                    JSONObject row=rows.getJSONObject(i);
                    String address=row.optString("data");
                    if (row.optInt("type") == 1 && address.matches("[0-9.]+")) result.add(InetAddress.getByName(address));
                }
                if (result.isEmpty()) throw new IOException();
                return result;
            } catch (Exception error) { throw new UnknownHostException("UC 授权域名解析失败"); }
        }).build();
    }
    private JSONObject request(String url, String token) throws Exception {
        FormBody.Builder form = new FormBody.Builder().add("client_id","381").add("v","1.2").add("request_id",requestID);
        if (token != null) form.add("token",token);
        Request.Builder request=new Request.Builder().url(url).header("User-Agent",UA).header("Origin","https://broccoli.uc.cn").header("Referer","https://drive.uc.cn/");
        if (url.startsWith("https://"+CAS+"/")) request.post(form.build());
        try (Response reply=client.newCall(request.build()).execute()) {
            if (!reply.isSuccessful() || reply.body() == null) throw new IOException("UC 授权接口连接失败");
            return new JSONObject(reply.body().string());
        }
    }
    public String token() throws Exception {
        String token = members(request("https://"+CAS+"/cas/ajax/getTokenForQrcodeLogin?__dt=159&__t="+requestID,null)).optString("token");
        if (token.isEmpty()) throw new IOException("UC 未生成二维码，请重试");
        return token;
    }
    private static JSONObject members(JSONObject root) {
        JSONObject data=root.optJSONObject("data");
        JSONObject members=data == null ? null : data.optJSONObject("members");
        return members == null ? new JSONObject() : members;
    }
    public String poll(String token) throws Exception {
        return members(request("https://"+CAS+"/cas/ajax/getServiceTicketByQrcodeToken?dt=6828&t="+System.currentTimeMillis(),token)).optString("service_ticket");
    }
    public JSONObject account(String ticket) throws Exception {
        HttpUrl url=HttpUrl.get("https://drive.uc.cn/account/mobileinfo").newBuilder().addQueryParameter("pr","UCBrowser").addQueryParameter("fr","h5").addQueryParameter("st",ticket).build();
        JSONObject root=request(url.toString(),null),data=root.optJSONObject("data");
        if (data == null || !PluginCookieCodec.valid("__pus="+data.optString("__pus"))) throw new IOException("UC 未返回登录 Cookie");
        return data;
    }
    public static String qrURL(String token) {
        return HttpUrl.get("https://broccoli.uc.cn/apps/ZY5qIZiK/routes/scan_confirm").newBuilder().addQueryParameter("token",token).addQueryParameter("client_id","381").addQueryParameter("uc_biz_str","S:custom|C:titlebar_fix").build().toString();
    }
    public void cancel() { client.dispatcher().cancelAll(); }
}
