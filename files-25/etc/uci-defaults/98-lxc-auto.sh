#!/bin/sh
# 首启写入 /etc/config/lxc-auto 的容器段。
#
# ★ 为什么是 uci-defaults，而不是 files/etc/config/lxc-auto（v.108.8）：
#   workflow 用 bind mount 把 custom/ 盖到 files/etc/config 上：
#       -v "${{ github.workspace }}/custom:/home/build/immortalwrt/files/etc/config"
#   Docker 的 bind mount 会整体遮蔽挂载点目录的原有内容，而 custom/ 在
#   git 里是空的（内容由 action 运行时生成），所以仓库里的
#   files/etc/config/lxc-auto 在构建容器里根本不存在 —— 镜像落回的是
#   lxc-auto 包自带的「全部注释」模板：
#       #config container
#       #	option name container1
#       #	option timeout 300
#       #	list command '/bin/command --option'
#   uci 解析时这些全是注释，一行有效配置都没有 → config_foreach 遍历不到
#   container 段 → /etc/init.d/lxc-auto start() 一声不响地什么都不做：
#   容器开机不常驻，而宿主日志干净得像没事。
#   换到 /etc/uci-defaults（不在 /etc/config 下，不受那个挂载影响）。
#
# 【v.108.30】幂等，但不再硬写名字：
#   原来这里把 name 固定写成 ubuntu。本脚本一旦跑第二遍（commit 失败后的
#   本次重试、有人手工重跑），容器名不是 ubuntu 的机器就会被这行改错 ——
#   lxc-auto 于是去起一个不存在的容器，开机静默不常驻。
#   现在：段在就只补「缺的字段」，名字从 $LXC_NAME 取（与引导脚本同一口径，
#   默认 ubuntu）；段不在才新建。真正的名字校正由引导的 lxc_auto 节点负责。
_LXC_NAME="${LXC_NAME:-ubuntu}"

if uci -q get lxc-auto.@container[0] >/dev/null 2>&1; then
    _cur_name="$(uci -q get lxc-auto.@container[0].name)"
    _cur_to="$(uci -q get lxc-auto.@container[0].timeout)"
    _changed=0
    [ -n "$_cur_name" ] || { uci -q set "lxc-auto.@container[0].name=$_LXC_NAME"; _changed=1; }
    [ -n "$_cur_to" ]   || { uci -q set "lxc-auto.@container[0].timeout=300"; _changed=1; }
else
    uci -q add lxc-auto container
    uci -q set "lxc-auto.@container[-1].name=$_LXC_NAME"
    uci -q set "lxc-auto.@container[-1].timeout=300"
    _changed=1
fi

# commit 失败返回 1 会保留本脚本，下次开机重试；成功才 exit 0 被框架删除
[ "$_changed" = 1 ] || exit 0
uci -q commit lxc-auto || exit 1
exit 0
