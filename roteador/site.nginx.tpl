# App Rede: API e teste de velocidade do roteador (porta 8077, só pela LAN).
# Gerado por /etc/init.d/netmon a partir de /etc/netmon/site.nginx.tpl.
# O token vem de /etc/netmon/token. Não editar o site.nginx: ele é refeito.
server {
	listen 8077;
	server_name _;
	access_log off;
	gzip off;

	set $nm_ok 0;
	if ($http_x_nm_token = "@TOKEN@") {
		set $nm_ok 1;
	}

	# identidade, sem token: o app confere se está falando com este roteador
	location = /nm/id {
		default_type application/json;
		add_header Cache-Control no-store;
		return 200 '{"app":"netmon","host":"$hostname","v":1}';
	}

	# download do teste de velocidade: arquivo esparso de 256 MB na RAM (não ocupa memória)
	location = /nm/dl {
		if ($nm_ok = 0) {
			return 403;
		}
		alias /tmp/netmon/blob;
		default_type application/octet-stream;
		add_header Cache-Control no-store;
	}

	# upload do teste: o nginx lê o pedido inteiro antes de responder (repasse ao /nm/sink)
	location = /nm/up {
		if ($nm_ok = 0) {
			return 403;
		}
		client_max_body_size 64m;
		client_body_buffer_size 8m;
		proxy_pass http://127.0.0.1:8077/nm/sink;
		proxy_set_header X-NM-Token "";
	}

	location = /nm/sink {
		allow 127.0.0.1;
		deny all;
		client_max_body_size 64m;
		return 204;
	}

	location = /nm/api {
		if ($nm_ok = 0) {
			return 403;
		}
		client_max_body_size 1m;
		fastcgi_read_timeout 90s;
		fastcgi_param SCRIPT_FILENAME /www/cgi-bin/netmon;
		fastcgi_param SCRIPT_NAME /cgi-bin/netmon;
		fastcgi_param QUERY_STRING $query_string;
		fastcgi_param REQUEST_METHOD $request_method;
		fastcgi_param CONTENT_TYPE $content_type;
		fastcgi_param CONTENT_LENGTH $content_length;
		fastcgi_param REMOTE_ADDR $remote_addr;
		fastcgi_param SERVER_PROTOCOL $server_protocol;
		fastcgi_param GATEWAY_INTERFACE CGI/1.1;
		fastcgi_pass 127.0.0.1:8920;
	}
}
