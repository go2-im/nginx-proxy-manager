  listen ${HTTP_PORT};
{% if ipv6 -%}
  listen [::]:${HTTP_PORT};
{% else -%}
  #listen [::]:${HTTP_PORT};
{% endif %}
{% if certificate -%}
  listen ${HTTPS_PORT} ssl;
{% if ipv6 -%}
  listen [::]:${HTTPS_PORT} ssl;
{% else -%}
  #listen [::]:${HTTPS_PORT};
{% endif %}
{% endif %}
  server_name {{ domain_names | join: " " }};
{% if http2_support == 1 or http2_support == true %}
  http2 on;
{% else -%}
  http2 off;
{% endif %}