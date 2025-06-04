module("luci.controller.fixttl.ttl", package.seeall)

function index()
    entry({"admin", "network", "fixttl"}, call("render_page"), _("Fix TTL"), 100).leaf = true
end

function get_saved_ttl()
    local uci = require "luci.model.uci".cursor()
    local ttl_str = uci:get("ttlconf", "config", "ttl")

    if not uci:get("ttlconf", "config") then
        uci:section("ttlconf", "ttlconf", "config", { ttl = "65" })
        uci:commit("ttlconf")
        ttl_str = "65"
    end

    local ttl_num = tonumber(ttl_str)
    if ttl_num and ttl_num > 0 and ttl_num < 256 then
        return ttl_num
    else
        return 65
    end
end

function save_ttl_config(ttl_value)
    local uci = require "luci.model.uci".cursor()

    -- Kalau belum ada section 'config', buat dulu
    if not uci:get("ttlconf", "config") then
        uci:section("ttlconf", "ttlconf", "config", {
            ttl = tostring(ttl_value)
        })
    else
        uci:set("ttlconf", "config", "ttl", tostring(ttl_value))
    end

    uci:commit("ttlconf")
end


function is_ttl_enabled()
    local output = luci.sys.exec("nft list chain inet fw4 mangle_postrouting_ttl65 2>/dev/null")
    return output and output:match("ip ttl set") ~= nil
end

function render_page()
    local http = require "luci.http"
    local sys = require "luci.sys"
    local tpl = require "luci.template"
    local dispatcher = require "luci.dispatcher"
    local action = http.formvalue("action")
    local ttl_input = tonumber(http.formvalue("ttl"))
    local log_path = "/tmp/fixttl.log"
    local ttl_file = "/etc/nftables.d/ttl65.nft"
    local log_lines = {}

    local function log(msg)
        table.insert(log_lines, msg)
    end

    -- Simpan TTL jika disubmit manual
    if ttl_input and ttl_input > 0 and ttl_input < 256 then
        save_ttl_config(ttl_input)
        log("TTL disimpan: " .. ttl_input)
    end

    -- Ambil TTL yang tersimpan
    local ttl_value = get_saved_ttl()

    if action == "toggle" then
        if is_ttl_enabled() then
            log("Menonaktifkan TTL...")
            sys.call("nft delete chain inet fw4 mangle_postrouting_ttl65 2>/dev/null")
            sys.call("nft delete chain inet fw4 mangle_prerouting_ttl65 2>/dev/null")
            local f = io.open(ttl_file, "w")
            if f then
                f:write("## Fix TTL - Dinonaktifkan\n")
                f:close()
            end
            sys.call("(sleep 2; /etc/init.d/firewall restart) &")
            log("TTL dinonaktifkan dan firewall direstart.")
        else
            log("Mengaktifkan TTL " .. ttl_value .. "...")
            local f = io.open(ttl_file, "w")
            if f then
                f:write(string.format([[
## Fix TTL - Aryo Brokolly (youtube)
chain mangle_postrouting_ttl65 {
    type filter hook postrouting priority 300; policy accept;
    counter ip ttl set %d
}
chain mangle_prerouting_ttl65 {
    type filter hook prerouting priority 300; policy accept;
    counter ip ttl set %d
}
]], ttl_value, ttl_value))
                f:close()
            end
            sys.call("nft -f " .. ttl_file)
            sys.call("(sleep 1; /etc/init.d/firewall restart) &")
            log("TTL " .. ttl_value .. " diaktifkan dan firewall direstart.")
        end

        local flog = io.open(log_path, "w")
        if flog then
            flog:write(table.concat(log_lines, "\n"))
            flog:close()
        end

        http.redirect(dispatcher.build_url("admin", "network", "fixttl"))
        return
    end

    -- Ambil isi log
    local status_msg = ""
    local f = io.open(log_path, "r")
    if f then
        status_msg = f:read("*a")
        f:close()
    end

    tpl.render("fixttl/page", {
        status_msg = status_msg,
        ttl_active = is_ttl_enabled(),
        ttl_value = ttl_value
    })
end
