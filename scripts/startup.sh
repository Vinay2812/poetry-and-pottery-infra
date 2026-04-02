#!/bin/bash

set -e

# =============================================================================
# Poetry & Pottery Infrastructure Setup Script
# =============================================================================
#
# This script:
# 1. Installs Docker (if not present)
# 2. Creates Docker network: poetry-and-pottery_postgres-data
# 3. Creates workspace directory
# 4. Clones repositories via GitHub auth token:
#    - https://github.com/Vinay2812/poetry-and-pottery-infra
#    - https://github.com/Vinay2812/poetry-and-pottery
#    - https://github.com/Vinay2812/poetry-and-pottery-api
# 5. Fetches ALL environment files from Cloudflare R2:
#    R2 paths (for each project: infra, client, server):
#    - envs/poetry-and-pottery/<project>/.env.local   -> <project-dir>/.env.local
#    - envs/poetry-and-pottery/<project>/.env.docker  -> <project-dir>/.env.docker
#    - envs/poetry-and-pottery/<project>/.env.prod    -> <project-dir>/.env.production
#
#    Then copies the appropriate .env based on ENV_TYPE:
#    - local      -> copies .env.local to .env
#    - production -> copies .env.production to .env
#    - docker     -> copies .env.docker to .env
# 6. Runs docker compose in order: database -> api -> client
# 7. (Optional) Installs Nginx + Certbot and configures reverse proxies with SSL:
#    - poetryandpottery.prodapp.club -> localhost:3005 (Client)
#    - api-pnp.prodapp.club          -> localhost:5050 (API, 50MB body limit)
#    - db-pnp.prodapp.club           -> localhost:5432 (Database)
#
# =============================================================================
#
# USAGE:
#   ./startup.sh [command]
#
# COMMANDS:
#   install     Install Docker only
#   setup       Full setup (install, clone, fetch envs)
#   start       Start all services
#   stop        Stop all services
#   status      Check service status
#   nginx       Install Nginx + Certbot and setup reverse proxies with SSL
#   all         Full setup and start (default)
#
# REQUIRED ENVIRONMENT VARIABLES:
#   GITHUB_TOKEN           GitHub personal access token for cloning private repos
#   R2_ENDPOINT            Cloudflare R2 endpoint URL (e.g., https://xxx.r2.cloudflarestorage.com)
#   R2_ACCESS_KEY_ID       R2 access key ID
#   R2_SECRET_ACCESS_KEY   R2 secret access key
#   R2_BUCKET              R2 bucket name
#
# OPTIONAL ENVIRONMENT VARIABLES:
#   WORKSPACE_DIR          Workspace directory (default: ~/poetry-and-pottery-workspace)
#   ENV_TYPE               Environment type: local, production, docker (default: local)
#
# EXAMPLE:
#   export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
#   export R2_ENDPOINT="https://account-id.r2.cloudflarestorage.com"
#   export R2_ACCESS_KEY_ID="your_access_key"
#   export R2_SECRET_ACCESS_KEY="your_secret_key"
#   export R2_BUCKET="poetry-and-pottery-envs"
#   export ENV_TYPE="production"  # or: local, docker
#   ./startup.sh all
#
# =============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
WORKSPACE_DIR="${WORKSPACE_DIR:-$HOME/poetry-and-pottery-workspace}"
DOCKER_VOLUME="poetry-and-pottery_postgres-data"

# R2 Configuration
R2_ENDPOINT="${R2_ENDPOINT:-}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
R2_BUCKET="${R2_BUCKET:-}"

# GitHub Configuration
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

# Environment type: local, production, docker
ENV_TYPE="${ENV_TYPE:-local}"

# Repository URLs
INFRA_REPO="https://github.com/Vinay2812/poetry-and-pottery-infra"
CLIENT_REPO="https://github.com/Vinay2812/poetry-and-pottery"
API_REPO="https://github.com/Vinay2812/poetry-and-pottery-api"

# Nginx Configuration
NGINX_CONF_NAME="poetry-and-pottery.conf"
NGINX_DOMAINS="poetryandpottery.prodapp.club api-pnp.prodapp.club db-pnp.prodapp.club"

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

detect_os() {
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            echo "$ID"
        else
            echo "linux"
        fi
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    else
        echo "unknown"
    fi
}

# =============================================================================
# Docker Installation
# =============================================================================

install_docker_linux() {
    local distro=$(detect_os)

    log_info "Detected Linux distribution: $distro"

    case "$distro" in
        ubuntu|debian)
            log_info "Installing Docker on Ubuntu/Debian..."

            # Remove old versions
            sudo apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

            # Install prerequisites
            sudo apt-get update
            sudo apt-get install -y \
                ca-certificates \
                curl \
                gnupg \
                lsb-release

            # Add Docker's official GPG key
            sudo install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/$distro/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            sudo chmod a+r /etc/apt/keyrings/docker.gpg

            # Set up repository
            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$distro \
                $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

            # Install Docker
            sudo apt-get update
            sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        centos|rhel|fedora)
            log_info "Installing Docker on CentOS/RHEL/Fedora..."

            # Remove old versions
            sudo yum remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine 2>/dev/null || true

            # Install prerequisites
            sudo yum install -y yum-utils

            # Add Docker repository
            sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

            # Install Docker
            sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;

        *)
            log_error "Unsupported Linux distribution: $distro"
            log_info "Please install Docker manually: https://docs.docker.com/engine/install/"
            exit 1
            ;;
    esac

    # Start and enable Docker
    sudo systemctl start docker
    sudo systemctl enable docker

    # Add current user to docker group
    sudo usermod -aG docker "$USER"

    log_success "Docker installed successfully"
    log_warning "You may need to log out and back in for group changes to take effect"
}

install_docker_macos() {
    log_info "Installing Docker on macOS..."

    if check_command brew; then
        brew install --cask docker
        log_success "Docker Desktop installed via Homebrew"
        log_warning "Please open Docker Desktop to complete setup"
    else
        log_error "Homebrew not found. Please install Docker Desktop manually:"
        log_info "https://docs.docker.com/desktop/install/mac-install/"
        exit 1
    fi
}

install_docker() {
    if check_command docker; then
        log_success "Docker is already installed: $(docker --version)"
        return 0
    fi

    log_info "Docker not found. Installing..."

    local os=$(detect_os)

    case "$os" in
        macos)
            install_docker_macos
            ;;
        ubuntu|debian|centos|rhel|fedora|linux)
            install_docker_linux
            ;;
        *)
            log_error "Unsupported operating system: $os"
            exit 1
            ;;
    esac
}

verify_docker() {
    log_info "Verifying Docker installation..."

    if ! check_command docker; then
        log_error "Docker command not found after installation"
        exit 1
    fi

    # Check if Docker daemon is running
    if ! docker info &> /dev/null; then
        log_warning "Docker daemon is not running"

        local os=$(detect_os)
        if [[ "$os" == "macos" ]]; then
            log_info "Please start Docker Desktop and run this script again"
            exit 1
        else
            log_info "Attempting to start Docker daemon..."
            sudo systemctl start docker
            sleep 3

            if ! docker info &> /dev/null; then
                log_error "Failed to start Docker daemon"
                exit 1
            fi
        fi
    fi

    # Verify docker compose
    if docker compose version &> /dev/null; then
        log_success "Docker Compose (plugin): $(docker compose version)"
    elif check_command docker-compose; then
        log_success "Docker Compose (standalone): $(docker-compose --version)"
    else
        log_error "Docker Compose not found"
        exit 1
    fi

    log_success "Docker is ready"
}

# =============================================================================
# Nginx & Certbot Installation
# =============================================================================

install_nginx() {
    if check_command nginx; then
        log_success "Nginx is already installed: $(nginx -v 2>&1)"
        return 0
    fi

    log_info "Nginx not found. Installing..."

    local os=$(detect_os)

    case "$os" in
        macos)
            if check_command brew; then
                brew install nginx
                log_success "Nginx installed via Homebrew"
            else
                log_error "Homebrew not found. Please install Nginx manually."
                exit 1
            fi
            ;;
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
            log_success "Nginx installed successfully"
            ;;
        centos|rhel|fedora)
            sudo yum install -y nginx
            sudo systemctl enable nginx
            sudo systemctl start nginx
            log_success "Nginx installed successfully"
            ;;
        *)
            log_error "Unsupported operating system: $os"
            exit 1
            ;;
    esac
}

install_certbot() {
    if check_command certbot; then
        log_success "Certbot is already installed: $(certbot --version 2>&1)"
        return 0
    fi

    log_info "Certbot not found. Installing..."

    local os=$(detect_os)

    case "$os" in
        macos)
            if check_command brew; then
                brew install certbot
                log_success "Certbot installed via Homebrew"
            else
                log_error "Homebrew not found. Please install Certbot manually."
                exit 1
            fi
            ;;
        ubuntu|debian)
            sudo apt-get update
            sudo apt-get install -y certbot python3-certbot-nginx
            log_success "Certbot installed successfully"
            ;;
        centos|rhel|fedora)
            sudo yum install -y certbot python3-certbot-nginx
            log_success "Certbot installed successfully"
            ;;
        *)
            log_error "Unsupported operating system: $os"
            exit 1
            ;;
    esac
}

setup_nginx() {
    log_info "Setting up Nginx configuration..."

    local nginx_source="$WORKSPACE_DIR/poetry-and-pottery-infra/nginx/$NGINX_CONF_NAME"
    local nginx_available="/etc/nginx/sites-available/$NGINX_CONF_NAME"
    local nginx_enabled="/etc/nginx/sites-enabled/$NGINX_CONF_NAME"

    # Check if source config exists
    if [ ! -f "$nginx_source" ]; then
        log_error "Nginx config not found: $nginx_source"
        log_info "Please ensure the repository is cloned first."
        exit 1
    fi

    # Copy config to sites-available
    log_info "Copying Nginx configuration to sites-available..."
    sudo cp "$nginx_source" "$nginx_available"
    log_success "Copied $NGINX_CONF_NAME to sites-available"

    # Create symlink to sites-enabled
    if [ -L "$nginx_enabled" ]; then
        log_warning "Symlink already exists, removing old one..."
        sudo rm "$nginx_enabled"
    fi

    log_info "Creating symlink in sites-enabled..."
    sudo ln -s "$nginx_available" "$nginx_enabled"
    log_success "Symlink created"

    # Test Nginx configuration
    log_info "Testing Nginx configuration..."
    if sudo nginx -t; then
        log_success "Nginx configuration is valid"
    else
        log_error "Nginx configuration test failed"
        exit 1
    fi

    # Reload Nginx
    log_info "Reloading Nginx..."
    sudo systemctl reload nginx || sudo nginx -s reload
    log_success "Nginx reloaded successfully"
}

setup_ssl_certificates() {
    log_info "Setting up SSL certificates with Certbot..."

    log_info "Requesting SSL certificates for: $NGINX_DOMAINS"
    log_warning "You will be prompted to enter your email and agree to terms."

    # Run certbot with nginx plugin
    sudo certbot --nginx

    if [ $? -eq 0 ]; then
        log_success "SSL certificates installed successfully"
    else
        log_error "Failed to obtain SSL certificates"
        log_info "You can retry manually with: sudo certbot --nginx"
        exit 1
    fi

    # Set up auto-renewal
    log_info "Testing certificate auto-renewal..."
    sudo certbot renew --dry-run

    if [ $? -eq 0 ]; then
        log_success "Certificate auto-renewal is configured"
    else
        log_warning "Auto-renewal test failed. Please check certbot configuration."
    fi
}

install_and_setup_nginx() {
    install_nginx
    install_certbot
    setup_nginx
    setup_ssl_certificates
}

# =============================================================================
# Network Setup
# =============================================================================

create_docker_volume() {
    log_info "Creating Docker network: $DOCKER_VOLUME"

    if docker volume inspect "$DOCKER_VOLUME" &> /dev/null; then
        log_success "Volume '$DOCKER_VOLUME' already exists"
    else
        docker volume create "$DOCKER_VOLUME"
        log_success "Volume '$DOCKER_VOLUME' created"
    fi
}

# =============================================================================
# Workspace Setup
# =============================================================================

create_workspace() {
    log_info "Creating workspace directory: $WORKSPACE_DIR"

    if [ -d "$WORKSPACE_DIR" ]; then
        log_warning "Workspace directory already exists"
    else
        mkdir -p "$WORKSPACE_DIR"
        log_success "Workspace directory created"
    fi

    cd "$WORKSPACE_DIR"
}

# =============================================================================
# Repository Cloning
# =============================================================================

clone_repo() {
    local repo_url="$1"
    local repo_name="$2"
    local branch="${3:-main}"
    local target_dir="$WORKSPACE_DIR/$repo_name"

    git config --global user.email "vinay2812@gmail.com"
    git config --global user.name "Vinay2812"

    log_info "Cloning $repo_name..."

    if [ -d "$target_dir" ]; then
        log_warning "$repo_name already exists, pulling latest changes from $branch..."
        cd "$target_dir"
        git checkout "$branch"
        git pull origin "$branch"
        cd "$WORKSPACE_DIR"
    else
        # Construct authenticated URL if token provided
        if [ -n "$GITHUB_TOKEN" ]; then
            local auth_url="${repo_url/https:\/\//https:\/\/$GITHUB_TOKEN@}"
            git clone -b "$branch" "$auth_url" "$target_dir"
        else
            git clone -b "$branch" "$repo_url" "$target_dir"
        fi
    fi

    log_success "$repo_name cloned successfully"
}

clone_repositories() {
    log_info "Cloning repositories..."

    if [ -z "$GITHUB_TOKEN" ]; then
        log_warning "GITHUB_TOKEN not set. Attempting to clone without authentication."
        log_warning "This may fail for private repositories."
    fi

    clone_repo "$INFRA_REPO" "poetry-and-pottery-infra"
    clone_repo "$CLIENT_REPO" "poetry-and-pottery"
    clone_repo "$API_REPO" "poetry-and-pottery-api"

    log_success "All repositories cloned"
}

# =============================================================================
# Environment Files
# =============================================================================

setup_aws_cli_for_r2() {
    log_info "Configuring AWS CLI for Cloudflare R2..."

    if [ -z "$R2_ENDPOINT" ] || [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ] || [ -z "$R2_BUCKET" ]; then
        log_error "R2 configuration incomplete. Please set:"
        log_error "  R2_ENDPOINT, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET"
        exit 1
    fi

    # Check for AWS CLI
    if ! check_command aws; then
        log_info "Installing AWS CLI..."

        local os=$(detect_os)
        case "$os" in
            macos)
                if check_command brew; then
                    brew install awscli
                else
                    curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
                    sudo installer -pkg AWSCLIV2.pkg -target /
                    rm AWSCLIV2.pkg
                fi
                ;;
            ubuntu|debian)
                # Use official AWS CLI v2 installer (apt package often unavailable)
                curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
                sudo apt-get update
                sudo apt-get install -y unzip
                unzip -q awscliv2.zip
                sudo ./aws/install
                rm -rf awscliv2.zip aws
                ;;
            centos|rhel|fedora)
                sudo yum install -y awscli
                ;;
            *)
                log_error "Please install AWS CLI manually: https://aws.amazon.com/cli/"
                exit 1
                ;;
        esac
    fi

    log_success "AWS CLI configured for R2"
}

fetch_env_file() {
    local r2_path="$1"
    local local_path="$2"
    local filename="$3"

    log_info "Fetching $filename from R2..."

    log_info "Copying s3://$R2_BUCKET/$r2_path -> $local_path"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$local_path")"

    # Fetch from R2 using AWS CLI with S3 compatibility
    # R2 requires --region auto for proper S3 API compatibility
    # Use env -u to properly unset AWS_PROFILE (prevents interference from ~/.aws/credentials)
    env -u AWS_PROFILE \
        AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" \
        AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" \
        aws s3 cp "s3://$R2_BUCKET/$r2_path" "$local_path" \
            --endpoint-url "$R2_ENDPOINT" \
            --region auto

    if [ -f "$local_path" ]; then
        log_success "Downloaded $filename"
    else
        log_error "Failed to download $filename"
        exit 1
    fi
}

fetch_all_env_files_for_project() {
    local r2_prefix="$1"
    local local_dir="$2"
    local project_name="$3"

    log_info "Fetching all env files for $project_name..."

    # Fetch .env.local
    # fetch_env_file \
    #     "$r2_prefix/.env.local" \
    #     "$local_dir/.env.local" \
    #     "$project_name/.env.local"

    # # Fetch .env.docker
    # fetch_env_file \
    #     "$r2_prefix/.env.docker" \
    #     "$local_dir/.env.docker" \
    #     "$project_name/.env.docker"

    # Fetch .env.prod and rename to .env.production
    fetch_env_file \
        "$r2_prefix/.env.prod" \
        "$local_dir/.env.production" \
        "$project_name/.env.prod -> .env.production"

    log_success "All env files fetched for $project_name"
}

fetch_environment_files() {
    log_info "Fetching all environment files from Cloudflare R2..."

    setup_aws_cli_for_r2

    # Fetch only .env.local for infra
    fetch_all_env_files_for_project \
        "poetry-and-pottery/infra" \
        "$WORKSPACE_DIR/poetry-and-pottery-infra/docker" \
        "infra"

    # Fetch all env files for client
    fetch_all_env_files_for_project \
        "poetry-and-pottery/client" \
        "$WORKSPACE_DIR/poetry-and-pottery" \
        "client"

    # Fetch all env files for server
    fetch_all_env_files_for_project \
        "poetry-and-pottery/server" \
        "$WORKSPACE_DIR/poetry-and-pottery-api" \
        "server"

    # Copy the appropriate .env based on ENV_TYPE for docker-compose compatibility
    log_info "Setting up .env symlinks based on ENV_TYPE: $ENV_TYPE"

    local source_file=""
    case "$ENV_TYPE" in
        local)
            source_file=".env.local"
            ;;
        production)
            source_file=".env.production"
            ;;
        docker)
            source_file=".env.docker"
            ;;
        *)
            log_warning "Unknown ENV_TYPE: $ENV_TYPE, defaulting to .env.local"
            source_file=".env.local"
            ;;
    esac

    # Infra always uses .env.local (only env file available)
    cp "$WORKSPACE_DIR/poetry-and-pottery-infra/docker/$source_file" "$WORKSPACE_DIR/poetry-and-pottery-infra/docker/.env"
    cp "$WORKSPACE_DIR/poetry-and-pottery/$source_file" "$WORKSPACE_DIR/poetry-and-pottery/.env"
    cp "$WORKSPACE_DIR/poetry-and-pottery-api/$source_file" "$WORKSPACE_DIR/poetry-and-pottery-api/.env"

    log_success "Copied $source_file to .env for client/server and infra"
    log_success "All environment files fetched successfully"
}

# =============================================================================
# Docker Compose
# =============================================================================

run_docker_compose_service() {
    local service_dir="$1"
    local display_name="$2"
    local compose_service="$3"
    local compose_file="${4:-docker-compose.yml}"

    cd "$service_dir"

    if [ ! -f "$compose_file" ]; then
        log_error "docker-compose.yml not found in $service_dir"
        exit 1
    fi

    # Stop and remove the service if it's already running
    log_info "Stopping and removing $display_name if running..."
    docker compose -f "$compose_file" stop "$compose_service" 2>/dev/null || true
    docker compose -f "$compose_file" rm -f "$compose_service" 2>/dev/null || true

    # Start the service
    log_info "Starting $display_name..."
    docker compose -f "$compose_file" --env-file .env.production up -d "$compose_service"
    log_success "$display_name started"

    cd "$WORKSPACE_DIR"
}

wait_for_service() {
    local service_name="$1"
    local max_attempts="${2:-30}"
    local check_command="$3"

    log_info "Waiting for $service_name to be ready..."

    local attempt=1
    while [ $attempt -le $max_attempts ]; do
        if eval "$check_command" &> /dev/null; then
            log_success "$service_name is ready"
            return 0
        fi

        echo -n "."
        sleep 2
        ((attempt++))
    done

    echo ""
    log_error "$service_name failed to start within timeout"
    return 1
}

start_services() {
    local infra_dir="$WORKSPACE_DIR/poetry-and-pottery-infra"

    log_info "Starting all services with Docker Compose..."

    # 1. Start Database
    log_info "=== Step 1: Starting Database ==="
    run_docker_compose_service "$infra_dir/docker" "Database" "database" "docker-compose.prod.yml"

    sleep 5  # Extra buffer for database initialization

    # 2. Start Redis
    log_info "=== Step 2: Starting Redis ==="
    run_docker_compose_service "$infra_dir/docker" "Redis" "redis" "docker-compose.prod.yml"

    # 2. Start API
    log_info "=== Step 3: Starting API ==="
    run_docker_compose_service "$infra_dir/docker" "API Server" "api" "docker-compose.prod.yml"

    sleep 5

    # # 3. Start Client
    # log_info "=== Step 4: Starting Client ==="
    # run_docker_compose_service "$infra_dir/docker" "Client" "client" "docker-compose.prod.yml"

    # sleep 5

    log_success "All services started successfully!"
}

# =============================================================================
# Status Check
# =============================================================================

check_status() {
    log_info "Checking service status..."

    echo ""
    echo "=== Docker Containers ==="
    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

    echo ""
    echo "=== Service Endpoints ==="
    echo "  Database:  postgres://localhost:5432"
    echo "  API:       http://localhost:5050"
    echo "  Client:    http://localhost:3005"
    echo "  Redis:     redis://localhost:6379"
    echo ""
}

# =============================================================================
# Cleanup
# =============================================================================

cleanup() {
    log_info "Stopping all services..."

    cd "$WORKSPACE_DIR/poetry-and-pottery-infra" && docker compose down 2>/dev/null || true

    log_success "All services stopped"
}

# =============================================================================
# Main
# =============================================================================

show_usage() {
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  install     Install Docker only"
    echo "  setup       Full setup (install, clone, fetch envs)"
    echo "  start       Start all services"
    echo "  stop        Stop all services"
    echo "  status      Check service status"
    echo "  nginx       Install and setup Nginx with SSL certificates"
    echo "  all         Full setup and start (default)"
    echo ""
    echo "Environment Variables:"
    echo "  WORKSPACE_DIR          Workspace directory (default: ~/poetry-and-pottery-workspace)"
    echo "  GITHUB_TOKEN           GitHub personal access token for cloning"
    echo "  R2_ENDPOINT            Cloudflare R2 endpoint URL"
    echo "  R2_ACCESS_KEY_ID       R2 access key ID"
    echo "  R2_SECRET_ACCESS_KEY   R2 secret access key"
    echo "  R2_BUCKET              R2 bucket name"
    echo "  ENV_TYPE               Environment type: local, production, docker (default: local)"
    echo ""
    echo "All .env files are fetched from R2 (.env.local, .env.docker, .env.prod -> .env.production)"
    echo "ENV_TYPE determines which one is copied to .env for docker-compose:"
    echo "  local       -> copies .env.local to .env"
    echo "  production  -> copies .env.production to .env"
    echo "  docker      -> copies .env.docker to .env"
    echo ""
    echo "Nginx Setup:"
    echo "  The 'nginx' command installs Nginx and Certbot, configures reverse proxies,"
    echo "  and obtains SSL certificates for:"
    echo "    - poetryandpottery.prodapp.club -> localhost:3005 (Client)"
    echo "    - api-pnp.prodapp.club          -> localhost:5050 (API, 50MB limit)"
    echo "    - db-pnp.prodapp.club           -> localhost:5432 (Database)"
    echo ""
}

main() {
    local command="${1:-all}"

    echo "=============================================="
    echo "  Poetry & Pottery Infrastructure Setup"
    echo "=============================================="
    echo ""

    case "$command" in
        install)
            install_docker
            verify_docker
            ;;
        setup)
            install_docker
            verify_docker
            create_DOCKER_VOLUME
            create_workspace
            clone_repositories
            fetch_environment_files
            ;;
        start)
            verify_docker
            start_services
            check_status
            ;;
        stop)
            cleanup
            ;;
        status)
            check_status
            ;;
        nginx)
            install_and_setup_nginx
            ;;
        all)
            install_docker
            verify_docker
            create_docker_volume
            create_workspace
            clone_repositories
            fetch_environment_files
            start_services
            check_status
            ;;
        help|--help|-h)
            show_usage
            ;;
        *)
            log_error "Unknown command: $command"
            show_usage
            exit 1
            ;;
    esac
}

main "$@"
