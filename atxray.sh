#!/bin/bash

VERSION=0.0.1
TEMPLATES_GIT_URL=https://github.com/TTTUUUIII/atxray.git
ATXRAY_HOME=${ATXRAY_HOME:-$HOME/.atxray}
ATXRAY_TMP=/tmp/tmp.ATXRAY

ACTION_INIT=1
ACTION_CONFIGURE=2
ACTION_ISSUE_CERT=3
ACTION_SHOW_HELP=4
ACTION_UPDATE=5

ACME=$HOME/.acme.sh/acme.sh
CERT_INSTALL_PATH=$HOME/.ssl

my_dir=$(pwd)
webroot=/var/www/html
action=0

function pr_error() {
	echo -e "\e[31m$1\e[0m"
}

function pr_warn() {
	echo -e "\e[33m$1\e[0m"
}

function parse_arg() {
	local index=$(expr index "$1" "=")
	local key=$1 value=""
	if [ $index -ne 0 ]; then
		key=${1:0:((index - 1))}
		value=${1:index}
	fi
	case $1 in
	--email*)
		email=$value
		;;
	--domain*)
		domain=$value
		;;
	--webroot*)
		webroot=$value
		;;
	--ca-server*)
		ca_server=$value
		;;
	--remark*)
		remark=$value
		;;
	--uuid*)
		uuid=$value
		;;
	--xray-tcp-port*)
		xray_tcp_port=$value
		;;
	--xray-ws-path*)
		xray_ws_path=$value
		;;
	--xray-ws-port*)
		xray_ws_port=$value
		;;
	--auto-issue-cert)
		auto_issue_cert=1
		;;
	--auto-configure)
		auto_configure=1
		;;
	--force-renew)
		force_renew=1
		;;
	install | init)
		action=$ACTION_INIT
		;;
	configure)
		action=$ACTION_CONFIGURE
		;;
	cert)
		action=$ACTION_ISSUE_CERT
		;;
	update)
		action=$ACTION_UPDATE
		;;
	help)
		action=$ACTION_SHOW_HELP
		;;
	*)
		if [ "${1:0:2}" == "--" ]; then
			pr_warn "Unknown option $key, ignored!"
		fi
		;;
	esac

}

function parse_args() {
	for arg in "$@"; do
		parse_arg $arg
	done

}

function requires() {
	for cmd in "$@"; do
		if ! $cmd --version >/dev/null 2>&1 && ! $cmd -version >/dev/null 2>&1; then
			pr_error "Failed! $cmd not install."
			exit 1
		fi
	done
}

function issue_cert() {
	requires $ACME
	local renew=${force_renew:-0}
	[ -z "$domain" ] && read -p "Input your domain: " domain
	if [ $renew -eq 1 ]; then
		$ACME --renew -d $domain --force
	else
		$ACME --issue -d $domain -w $webroot --keylength ec-256 --server ${ca_server:-zerossl}
		if [ $? -eq 0 ]; then
			mkdir -p $CERT_INSTALL_PATH
			$ACME --install-cert -d $domain --key-file "$CERT_INSTALL_PATH/$domain.key" --fullchain-file "$CERT_INSTALL_PATH/$domain.pem" --reloadcmd "systemctl reload nginx.service > /dev/null 2>&1"
			$ACME --info -d $domain
		fi
	fi
	return $?
}

function install() {
	local auto_issue_cert=${auto_issue_cert:-0}
	local auto_configure=${auto_configure:-0}
	# install nginx
	if ! nginx -version >/dev/null 2>&1; then
		apt update
		apt install nginx -y
	else
		pr_warn "nginx already installed, skipped."
	fi

	# install acme.sh
	if ! $ACME --version >/dev/null 2>&1; then
		[ -z "$email" ] && read -p "Input your email: " email
		curl https://get.acme.sh | sh -s email=$email
	else
		pr_warn "acme.sh already installed, skipped."
	fi

	# install xray
	if ! xray --version >/dev/null 2>&1; then
		bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install -u root
	else
		pr_warn "xray already installed, skipped."
	fi

	# if auto_issue_cert option is specified, we still need issue cert.
	if [ $auto_issue_cert -eq 1 ]; then
		issue_cert
		# if auto_configure option is specified, we still need call configure function.
		if [ $? -eq 0 ] && [ $auto_configure -eq 1 ]; then
			configure
		fi
	fi
}

function configure() {
	requires git xray /usr/sbin/nginx
	if [ ! -d $ATXRAY_HOME/templates ]; then
		echo "Fetch templates from $TEMPLATES_GIT_URL"
		if ! git clone $TEMPLATES_GIT_URL $ATXRAY_HOME; then
			exit 1
		fi
	fi
	if [ ! -d $ATXRAY_TMP ]; then
		if ! mkdir $ATXRAY_TMP; then
			exit 1
		fi
	fi
	local index=1
	echo "+-------------------------------+"
	for it in $ATXRAY_HOME/templates/*; do
		[ -d $it ] && templates+=($(basename $it))
		printf "| %-2d. %-25s |\n" $index $(basename $it)
		((index++))
	done
	echo "+-------------------------------+"
	read -p "Select a template: " tid
	if [[ "$tid" =~ ^[0-9]+$ ]] && [ $tid -gt 0 ]; then
		local choose=${templates[((tid - 1))]}
	else
		pr_error "\"$tid\" is invalid input!"
		exit 1
	fi
	local uuid=${uuid:-$(xray uuid)}
	local scheme="vless:"
	if [ -z $choose ]; then
		pr_error "The template with id \"$tid\" was not found!"
		exit 1
	else
		echo -e "Your choice is \e[33m$choose\e[0m"
	fi
	case $choose in
	vless+tcp+tls | vless+tcp+xtls-vision)
		[ -z "$domain" ] && read -p "Input your domain: " domain
		local xray_tcp_port=${xray_tcp_port:-443}
		local authority="//$uuid@$domain:$xray_tcp_port"
		cp -r $ATXRAY_HOME/templates/$choose $ATXRAY_TMP && cd $ATXRAY_TMP/$choose
		if [ $template == "vless+tcp+xtls-vision" ]; then
			local flow="xtls-rprx-vision"
		fi
		local query="?security=tls&encryption=none&alpn=h2,http/1.1&headerType=none&flow=${flow:-none}&fp=chrome&type=tcp&sni=$domain#${remark:-Default}"
		sed -i "s#\$uuid#$uuid#g" server.json &&
			sed -i "s#\$xray_tcp_port#$xray_tcp_port#g" server.json &&
			sed -i "s#\$email#$email#g" server.json &&
			sed -i "s#\$domain#$domain#g" server.json &&
			sed -i "s#\$ssl_fullchain#$CERT_INSTALL_PATH/$domain.pem#g" server.json &&
			sed -i "s#\$ssl_key#$CERT_INSTALL_PATH/$domain.key#g" server.json &&
			sed -i "s#\$domain#$domain#g" nginx.conf &&
			sed -i "s#\$webroot#$webroot#g" nginx.conf
		;;
	vless+ws+web)
		[ -z "$domain" ] && read -p "Input your domain: " domain
		local xray_ws_path=${xray_ws_path:-/v0}
		local xray_ws_port=${xray_ws_port:-8081}
		local authority="//$uuid@$domain:443"
		local query="?path=$xray_ws_path&security=tls&encryption=none&alpn=http/1.1&host=$domain&type=ws&sni=$domain#${remark:-Default}"
		cp -r $ATXRAY_HOME/templates/$choose $ATXRAY_TMP &&
			cd $ATXRAY_TMP/$choose &&
			sed -i "s#\$uuid#$uuid#g" server.json &&
			sed -i "s#\$xray_ws_port#$xray_ws_port#g" server.json &&
			sed -i "s#\$xray_ws_path#$xray_ws_path#g" server.json &&
			sed -i "s#\$domain#$domain#g" nginx.conf &&
			sed -i "s#\$webroot#$webroot#g" nginx.conf &&
			sed -i "s#\$ssl_fullchain#$CERT_INSTALL_PATH/$domain.pem#g" nginx.conf &&
			sed -i "s#\$ssl_key#$CERT_INSTALL_PATH/$domain.key#g" nginx.conf &&
			sed -i "s#\$xray_ws_path#$xray_ws_path#g" nginx.conf &&
			sed -i "s#\$xray_ws_port#$xray_ws_port#g" nginx.conf
		;;
	*)
		pr_error "Unknown template \"$choose\"."
		exit 1
		;;
	esac

	local temp_dir=$(pwd)
	if [ $? -eq 0 ]; then
		local share_uri=$(echo -n "$scheme$authority$query" | base64)
		cp nginx.conf /etc/nginx/sites-available/$domain &&
			rm -rf /etc/nginx/sites-e/$domain &&
			ln -sf /etc/nginx/sites-available/$domain /etc/nginx/sites-enabled/$domain &&
			mkdir -p /usr/local/etc/xray/conf.d &&
			cp server.json /usr/local/etc/xray/conf.d/${choose}.json &&
			rm -f /usr/local/etc/xray/conf.d/config.json &&
			ln -sf /usr/local/etc/xray/conf.d/${choose}.json /usr/local/etc/xray/config.json &&
			systemctl stop xray.service &&
			systemctl stop nginx.service &&
			systemctl start nginx.service &&
			systemctl start xray.service &&
			echo -e "\e[32m$share_uri\e[0m"
	else
		pr_error "Generate configuration failed!"
		exit 1
	fi

	cd $my_dir && rm -rf $temp_dir
}

function show_help() {

	echo """
Version $VERSION
Usage: xray_helper.sh [ACTION] [OPTION]...

Actions:
    init or install             xray[https://xtls.github.io/]、nginx[https://nginx.org/]、acme.sh[https://github.com/acmesh-official/acme.sh] will be installed.
		--auto-issue-cert, --auto-configure
    configure                   generate xray configure.
		--domain, --email
    cert                        issue a ssl cert use acme.sh.
		--domain
    help                        show this help.
	update						update atxray.sh and templates.

Options:
    --email                     specify a email.
    --domain                    specify domain.
    --webroot                   specify web root. (default: /var/www/html)
    --auto-issue-cert           vaild when action is install (or init), when this option was specified, an ssl cert will be automatically issue a cert after installed.
    --auto-configure        vaild when action is install (or init) and --auto-issue-cert is specified.
	--ca-server					specify ca server for acme.sh.
		supported CA:
			- zerossl
			- letsencrypt
			- buypass
			- ssl
			- google
    --force-renew               force renew the certs.
    --remark                    specify configuration alias.
    --uuid                      specify configuration uuid.
    --xray-tcp-port             xray tcp port.
    --xray-ws-port              xray ws port.
    --xray-ws-path              xray ws path.

Examples:
    xray_helper.sh init --email=example@gmail.com                       initialize environment for xray.
    xray_helper.sh cert --domain=example.com                            issue and install cert use acme.sh.
    xray_helper.sh configure --domain=example.com                       generate xray configuration.
"""

}

parse_args $@

case $action in
$ACTION_INIT)
	install
	;;
$ACTION_CONFIGURE)
	configure
	;;
$ACTION_ISSUE_CERT)
	issue_cert
	;;
$ACTION_UPDATE)
	cd $ATXRAY_HOME && git pull
	;;
$ACTION_SHOW_HELP)
	show_help
	;;
*)
	if [ -z "$1" ]; then
		pr_warn "no action specified!"
	else
		pr_error "unknown \"$1\" action!"
	fi
	show_help
	exit 1
	;;
esac

exit $?
