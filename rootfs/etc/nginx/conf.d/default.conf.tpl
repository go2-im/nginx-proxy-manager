# "You are not configured" page, which is the default if another default doesn't exist
server {
	listen ${HTTP_PORT};
	listen [::]:${HTTP_PORT};

	set $forward_scheme "http";
	set $server "127.0.0.1";
	set $port "${HTTP_PORT}";

	server_name localhost-nginx-proxy-manager;
	access_log /data/logs/fallback_access.log standard;
	error_log /data/logs/fallback_error.log warn;
	include conf.d/include/assets.conf;
	include conf.d/include/block-exploits.conf;
	include conf.d/include/letsencrypt-acme-challenge.conf;

	location / {
		index index.html;
		root /var/www/html;
	}
}

# First 443 Host, which is the default if another default doesn't exist
server {
	listen ${HTTPS_PORT} ssl;
	listen [::]:${HTTPS_PORT} ssl;

	set $forward_scheme "https";
	set $server "127.0.0.1";
	set $port "${HTTPS_PORT}";

	server_name localhost;
	access_log /data/logs/fallback_access.log standard;
	error_log /dev/null crit;
	include conf.d/include/ssl-ciphers.conf;
	ssl_reject_handshake on;

	return 444;
}