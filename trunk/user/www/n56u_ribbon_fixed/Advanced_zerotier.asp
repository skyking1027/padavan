<% nvram_update(); %>
<script type="text/javascript" src="/js/validator.js"></script>
<script type="text/javascript">
function zero_apply(){
    showLoading();
    var url = "/start_apply.htm";
    var param = getParameter();
    sendRequest(url, param, null, null, "apply");
}

function zero_check(){
    if (document.form.zerotier_enable.checked == true){
        if (document.form.zerotier_id.value == ""){
            alert("请输入 ZeroTier Network ID！");
            return false;
        }
        if (!/^[0-9a-fA-F]{16}$/.test(document.form.zerotier_id.value)){
            alert("Network ID 必须是 16 位十六进制字符串！");
            return false;
        }
    }
    zero_apply();
}
</script>

<div id="maincontent">
<h2>ZeroTier 组网服务</h2>
<form method="post" name="form" action="/start_apply.htm" onsubmit="return false;">
<input type="hidden" name="action_mode" value=" Refresh ">
<input type="hidden" name="action_script" value=" restart_zerotier ">
<input type="hidden" name="custom" value="">

<table class="input" width="100%" border="1" align="center" cellpadding="4" cellspacing="0" bordercolor="#6b8fa3" style="border-collapse:collapse;">
<tr>
    <th colspan="2">基本设置</th>
</tr>
<tr>
    <td width="35%"><B>启用 ZeroTier</B></td>
    <td><input type="checkbox" name="zerotier_enable" value="1" <% nvram_match("zerotier_enable", "1", "checked"); %> /></td>
</tr>
<tr>
    <td><B>ZeroTier Network ID</B> <small>16位十六进制ID，如：a1b2c3d4e5f67890</small></td>
    <td><input type="text" name="zerotier_id" maxlength="16" size="20" value="<% nvram_get("zerotier_id"); %>" /></td>
</tr>
<tr>
    <td><B>本地监听端口</B> <small>默认留空（随机），可填 9993</small></td>
    <td><input type="text" name="zerotier_port" maxlength="5" size="8" value="<% nvram_get("zerotier_port"); %>" /></td>
</tr>
<tr>
    <td><B>额外启动参数</B> <small>高级用户使用，如 -Ddebug</small></td>
    <td><input type="text" name="zerotier_args" size="30" value="<% nvram_get("zerotier_args"); %>" /></td>
</tr>

<tr>
    <th colspan="2">Moon 中继节点</th>
</tr>
<tr>
    <td><B>加入 Moon 节点</B> <small>填写 Moon 的 10 位 ID</small></td>
    <td><input type="text" name="zerotier_moonid" maxlength="10" size="15" value="<% nvram_get("zerotier_moonid"); %>" /></td>
</tr>
<tr>
    <td><B>本机作为 Moon 服务器</B></td>
    <td>
        <input type="checkbox" name="zerotiermoon_enable" value="1" <% nvram_match("zerotiermoon_enable", "1", "checked"); %> />
        &nbsp;&nbsp;公网 IP：<input type="text" name="zerotiermoon_ip" size="15" value="<% nvram_get("zerotiermoon_ip"); %>" />
         <small>留空则自动获取 WAN IP</small>
    </td>
</tr>

<tr>
    <th colspan="2">网络与路由</th>
</tr>
<tr>
    <td><B>启用 NAT（允许访问内网）</B></td>
    <td><input type="checkbox" name="zerotier_nat" value="1" <% nvram_match("zerotier_nat", "1", "checked"); %> /></td>
</tr>

<tr>
    <th colspan="2">状态信息</th>
</tr>
<tr>
    <td>设备 ID</td>
    <td><% nvram_get("zerotierdev_id"); %></td>
</tr>
<tr>
    <td>当前状态</td>
    <td><% nvram_get("zerotier_status"); %></td>
</tr>
<tr>
    <td>当前版本</td>
    <td><% nvram_get("zerotier_ver"); %></td>
</tr>
<tr>
    <td>最新版本</td>
    <td><% nvram_get("zerotier_ver_n"); %>
        <input type="button" value="检查更新" onclick="location.href='/start_apply.htm?action_mode=Refresh&action_script=check_zt_version&next_page=Advanced_ZeroTier.asp';" />
    </td>
</tr>
</table>

 
<center>
<input class="button_gen" type="button" onclick="zero_check();" value="应用设置" />
<input class="button_gen" type="button" onclick="location.href='Advanced_ZeroTier.asp';" value="刷新" />
</center>

<!-- 静态路由部分（可选扩展） -->
<%
int i, num = 3;
char nv_name[32];
for (i = 0; i < num; i++) {
    sprintf(nv_name, "zero_enable_x%d", i);
    int enable = nvram_match(nv_name, "1", 1);
    sprintf(nv_name, "zero_ip_x%d", i);
    char *ip = nvram_safe_get(nv_name);
    sprintf(nv_name, "zero_route_x%d", i);
    char *route = nvram_safe_get(nv_name);
%>
<input type="hidden" name="zero_enable_x<%=i%>" value="<%=enable%>" />
<input type="hidden" name="zero_ip_x<%=i%>" value="<%=ip%>" />
<input type="hidden" name="zero_route_x<%=i%>" value="<%=route%>" />
<% } %>
<input type="hidden" name="zero_staticnum_x" value="<%=num%>" />

</form>
</div>
