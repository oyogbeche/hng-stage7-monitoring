#!/bin/bash

# Script to install and configure Prometheus, Node Exporter, Blackbox Exporter,
# Alertmanager, Grafana, Pushgateway, and DORA Exporter as systemd services

# Exit on error
set -e

# Variables
MONITORING_DIR="/home/ubuntu/monitoring"
PROMETHEUS_VERSION="2.50.1"
NODE_EXPORTER_VERSION="1.7.0"
BLACKBOX_EXPORTER_VERSION="0.24.0"
ALERTMANAGER_VERSION="0.27.0"
GRAFANA_VERSION="10.4.1"
PUSHGATEWAY_VERSION="1.7.0"
DORA_EXPORTER_VERSION="0.2.0"

# Create monitoring directory
mkdir -p $MONITORING_DIR/{prometheus,node_exporter,blackbox_exporter,alertmanager,grafana,pushgateway,dora_exporter}
mkdir -p $MONITORING_DIR/{prometheus,alertmanager,blackbox_exporter}/data

echo "Installing dependencies..."
apt-get update
apt-get install -y wget tar curl unzip adduser libfontconfig1 apt-transport-https software-properties-common

# Create users for each service
for SERVICE in prometheus alertmanager blackbox_exporter node_exporter pushgateway dora_exporter; do
    if ! id "$SERVICE" &>/dev/null; then
        useradd --no-create-home --shell /bin/false $SERVICE
    fi
done

# Ensure monitoring directory exists
mkdir -p $MONITORING_DIR
chown -R ubuntu:ubuntu $MONITORING_DIR

# Function to download and setup a service
setup_service() {
    local service=$1
    local version=$2
    local binary_name=${3:-$service}
    local download_url=${4:-"https://github.com/prometheus/$service/releases/download/v$version/${service}-$version.linux-amd64.tar.gz"}
    
    echo "Setting up $service..."
    
    # Download and extract
    wget -O /tmp/$service.tar.gz $download_url
    tar xvfz /tmp/$service.tar.gz -C /tmp/
    
    # Move binary to /usr/local/bin
    cp /tmp/$service-$version.linux-amd64/$binary_name /usr/local/bin/
    
    # Set ownership and permissions
    chown ${service}:${service} /usr/local/bin/$binary_name
    chmod 755 /usr/local/bin/$binary_name
    chmod o+rx /home/ubuntu

    
    # Create directories if they don't exist
    mkdir -p $MONITORING_DIR/$service
    if [[ "$service" == "prometheus" || "$service" == "alertmanager" || "$service" == "blackbox_exporter" ]]; then
        mkdir -p $MONITORING_DIR/$service/data
        chown -R $service:$service $MONITORING_DIR/$service/data
        chmod -R 755 $MONITORING_DIR/$service/data
    fi
    
    # Cleanup
    rm -rf /tmp/$service*
}

# Install Prometheus
setup_service prometheus $PROMETHEUS_VERSION prometheus
cat > $MONITORING_DIR/prometheus/prometheus.yml << EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'prometheus'
    static_configs:
      - targets: ['localhost:9090']
  
  - job_name: 'node_exporter'
    static_configs:
      - targets: ['localhost:9100']
  
  - job_name: 'blackbox_exporter'
    metrics_path: /probe
    params:
      module: [http_2xx , http_2xx_with_latency, http_response_time, ssl_expiry]
    static_configs:
      - targets: 
        - https://genz.ad
        - https://api.genz.ad
        - https://staging.genz.ad
        - https://staging.api.genz.ad
    relabel_configs:
      - source_labels: [__address__]
        target_label: __param_target
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: localhost:9115
  
  - job_name: 'pushgateway'
    static_configs:
      - targets: ['localhost:9091']
  
  - job_name: 'dora_exporter'
    static_configs:
      - targets: ['localhost:9321']

alerting:
  alertmanagers:
  - static_configs:
    - targets: ['localhost:9093']

rule_files:
  - "alerts.yml"
EOF

# Create custom alerts.yml file
cat > $MONITORING_DIR/prometheus/alerts.yml << EOF
groups:
  - name: 'node_exporter'
    rules:
      - alert: HighCPUUsage
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100) > 80
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High CPU usage detected on {{ \$labels.instance }}"
          description: "CPU usage has exceeded 80% for over 2 minutes."

      - alert: CPUUsageRecovered
        expr: 100 - (avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[2m])) * 100) < 80
        for: 2m
        labels:
          severity: info
        annotations:
          summary: "CPU usage back to normal on {{ \$labels.instance }}"
          description: "CPU usage is now below 80%."
      
      - alert: HighMemoryUsage
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 > 80
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "High Memory usage detected on {{ \$labels.instance }}"
          description: "Memory usage has exceeded 80% for over 2 minutes."
      
      - alert: MemoryUsageRecovered
        expr: (node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) / node_memory_MemTotal_bytes * 100 < 80
        for: 2m
        labels:
          severity: info
        annotations:
          summary: "Memory usage back to normal on {{ \$labels.instance }}"
          description: "Memory usage is now below 80%."

  - name: 'blackbox_exporter'
    rules:
      - alert: ServerDown
        expr: probe_success == 0
        for: 1m
        labels:
          severity: critical
        annotations:
          summary: "Server is DOWN! {{ \$labels.instance }}"
          description: "Server has been unreachable for more than 1 minute."
      
      - alert: ServerRecovered
        expr: probe_success == 1
        for: 1m
        labels:
          severity: info
        annotations:
          summary: "Server is back online {{ \$labels.instance }}"
          description: "The server is now reachable."
EOF

cat > /etc/systemd/system/prometheus.service << EOF
[Unit]
Description=Prometheus
Wants=network-online.target
After=network-online.target

[Service]
User=prometheus
Group=prometheus
Type=simple
ExecStart=/usr/local/bin/prometheus \
    --config.file=$MONITORING_DIR/prometheus/prometheus.yml \
    --storage.tsdb.path=$MONITORING_DIR/prometheus/data \
    --web.console.templates=/etc/prometheus/consoles \
    --web.console.libraries=/etc/prometheus/console_libraries

[Install]
WantedBy=multi-user.target
EOF

# Install Node Exporter
setup_service node_exporter $NODE_EXPORTER_VERSION node_exporter
cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=node_exporter
Group=node_exporter
Type=simple
ExecStart=/usr/local/bin/node_exporter \
    --collector.cpu \
    --collector.meminfo \
    --collector.filesystem \
    --collector.loadavg \
    --collector.diskstats \
    --web.listen-address=:9100

[Install]
WantedBy=multi-user.target
EOF

# Install Blackbox Exporter
setup_service blackbox_exporter $BLACKBOX_EXPORTER_VERSION blackbox_exporter
cat > $MONITORING_DIR/blackbox_exporter/blackbox.yml << EOF
modules:
  http_2xx:
    prober: http
    timeout: 10s
    http:
      valid_status_codes: [200]
      method: GET
      headers:
        Host: "genz.ad" 
      no_follow_redirects: false
      fail_if_ssl: false
      fail_if_not_ssl: true
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false

  http_2xx_with_latency:
    prober: http
    timeout: 10s
    http:
      valid_status_codes: [200]
      method: GET
      headers:
        Host: "genz.ad"
      no_follow_redirects: false
      fail_if_ssl: false
      fail_if_not_ssl: true
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false

  ssl_expiry:
    prober: http
    timeout: 10s
    http:
      valid_status_codes: [] 
      method: GET
      headers:
        Host: "genz.ad"
      no_follow_redirects: false
      fail_if_ssl: false
      fail_if_not_ssl: true
      preferred_ip_protocol: "ip4"
      tls_config:
        insecure_skip_verify: false


EOF

cat > /etc/systemd/system/blackbox_exporter.service << EOF
[Unit]
Description=Blackbox Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=blackbox_exporter
Group=blackbox_exporter
Type=simple
ExecStart=/usr/local/bin/blackbox_exporter \
    --config.file=$MONITORING_DIR/blackbox_exporter/blackbox.yml \
    --web.listen-address=:9115
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Install AlertManager
setup_service alertmanager $ALERTMANAGER_VERSION alertmanager
cat > $MONITORING_DIR/alertmanager/alertmanager.yml << EOF
global:
  resolve_timeout: 5m
route:
  receiver: 'slack-alerts'
  group_by: ['serverity' , instance]
  group_wait: 10s
  group_interval: 5m
  repeat_interval: 1h
  routes:
    - match:
        severity: "critical"
      group_by: ['serverity' , instance]
      group_wait: 10s
      group_interval: 1m
      repeat_interval: 15m
      receiver: 'slack-alerts'
    - match:
        severity: "warning"
      group_by: ['serverity' , instance]
      group_wait: 2m
      group_interval: 5m
      repeat_interval: 1h
      receiver: 'slack-alerts'
    - match:
        severity: "info"
      group_by: ['serverity' , instance]
      group_wait: 2m
      group_interval: 10m
      repeat_interval: 4h
      receiver: 'slack-alerts'
receivers:
  - name: 'slack-alerts'
    slack_configs:
      - channel: "#DevOps-Alerts"
        api_url: "slack-webhook-url"
        send_resolved: true
        text: "{{ range .Alerts }}{{ if or (eq .Status \"resolved\") (eq .Status \"recovered\") }}🟢 {{ .Annotations.summary }}{{ else }}🔥 {{ .Annotations.summary }}{{ end }}\n\n📌 Description:\n{{ .Annotations.description }}\n\n🔍 Details:\n{{ range .Labels.SortedPairs }}• {{ .Name }}: {{ .Value }}\n{{ end }}\n\n👥 DevOps Team:\n<@U08AD13BJLX> <@U08BC0TS0JU> <@U08AMNS7V6W> <@U08AHB1D85C>\n{{ end }}"
EOF

cat > /etc/systemd/system/alertmanager.service << EOF
[Unit]
Description=Alertmanager
Wants=network-online.target
After=network-online.target

[Service]
User=alertmanager
Group=alertmanager
Type=simple
ExecStart=/usr/local/bin/alertmanager \
    --config.file=$MONITORING_DIR/alertmanager/alertmanager.yml \
    --storage.path=$MONITORING_DIR/alertmanager/data
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Install Grafana
echo "Installing Grafana..."
wget -q -O - https://packages.grafana.com/gpg.key | apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | tee -a /etc/apt/sources.list.d/grafana.list
apt-get update
apt-get install -y grafana

cat > /etc/grafana/grafana.ini << EOF
[server]
http_port = 4000
domain = localhost

[security]
admin_user = admin
admin_password = admin

[auth.anonymous]
enabled = true
org_name = Main Org.
org_role = Viewer
EOF

cat > /etc/systemd/system/grafana-server.service << EOF
[Unit]
Description=Grafana server
Documentation=http://docs.grafana.org
Wants=network-online.target
After=network-online.target

[Service]
User=grafana
Group=grafana
Type=simple
ExecStart=/usr/sbin/grafana-server \
    --config=/etc/grafana/grafana.ini \
    --homepath=/usr/share/grafana \
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

chmod -R 755 /usr/share/grafana

# Install Pushgateway
setup_service pushgateway $PUSHGATEWAY_VERSION pushgateway
cat > /etc/systemd/system/pushgateway.service << EOF
[Unit]
Description=Pushgateway
Wants=network-online.target
After=network-online.target

[Service]
User=pushgateway
Group=pushgateway
Type=simple
ExecStart=/usr/local/bin/pushgateway
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


# Set permissions for config files
chown -R prometheus:prometheus $MONITORING_DIR/prometheus
chown -R alertmanager:alertmanager $MONITORING_DIR/alertmanager
chown -R blackbox_exporter:blackbox_exporter $MONITORING_DIR/blackbox_exporter

# Reload systemd, enable and start services
systemctl daemon-reload

# Enable and start services
for SERVICE in prometheus node_exporter blackbox_exporter alertmanager grafana-server pushgateway dora_exporter; do
    systemctl enable $SERVICE
    systemctl start $SERVICE
    systemctl status $SERVICE --no-pager
done

echo "Installation completed. Service ports:"
echo "Prometheus: 9090"
echo "Node Exporter: 9100"
echo "Blackbox Exporter: 9115"
echo "Alertmanager: 9093"
echo "Grafana: 4000"
echo "Pushgateway: 9091"

echo "Configuration files are located in $MONITORING_DIR"
echo "Monitoring stack setup complete!"