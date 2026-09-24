#!/bin/bash
#
# Azure Infrastructure Teardown
#
# Destroys the AKS cluster and optionally the entire resource group.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../common.sh"

# Load configuration
if [ -f "${SCRIPT_DIR}/config.env" ]; then
    source "${SCRIPT_DIR}/config.env"
fi

# Configuration
RESOURCE_GROUP="${RESOURCE_GROUP:-hyperlight-rg}"
CLUSTER_NAME="${CLUSTER_NAME:-hyperlight-cluster}"
ASSUME_YES=false
WAIT_FOR_DELETION=false

usage() {
    echo "Usage: $0 [--cluster-only | --all] [--yes] [--wait]"
    echo ""
    echo "Options:"
    echo "  --cluster-only  Delete only the AKS cluster (keep resource group, ACR)"
    echo "  --all           Delete the entire resource group (default)"
    echo "  --yes           Skip the interactive confirmation"
    echo "  --wait          Wait until Azure confirms deletion"
    echo ""
    echo "Environment variables:"
    echo "  RESOURCE_GROUP  Resource group name (default: hyperlight-rg)"
    echo "  CLUSTER_NAME    AKS cluster name (default: hyperlight-cluster)"
}

confirm_delete() {
    local prompt=$1
    if [ "$ASSUME_YES" = true ]; then
        return
    fi
    read -r -p "$prompt (yes/no): " confirm
    if [ "$confirm" != "yes" ]; then
        log_info "Cancelled"
        exit 0
    fi
}

delete_cluster_only() {
    log_warning "Deleting AKS cluster: ${CLUSTER_NAME}"
    
    if ! az aks show -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" &> /dev/null; then
        log_warning "Cluster not found"
        return
    fi
    
    confirm_delete "Delete cluster ${CLUSTER_NAME}?"
    
    local args=(aks delete -g "${RESOURCE_GROUP}" -n "${CLUSTER_NAME}" --yes)
    if [ "$WAIT_FOR_DELETION" = false ]; then
        args+=(--no-wait)
    fi
    az "${args[@]}"
    
    if [ "$WAIT_FOR_DELETION" = true ]; then
        log_success "Cluster deleted"
    else
        log_success "Cluster deletion initiated (running in background)"
    fi
    log_info "ACR and resource group preserved"
}

delete_resource_group() {
    log_warning "Deleting resource group: ${RESOURCE_GROUP}"
    log_warning "This will delete ALL resources including:"
    log_warning "  - AKS cluster: ${CLUSTER_NAME}"
    log_warning "  - ACR and all images"
    log_warning "  - Any other resources in the group"
    
    if ! az group show --name "${RESOURCE_GROUP}" &> /dev/null; then
        log_warning "Resource group not found"
        return
    fi
    
    confirm_delete "Delete entire resource group?"
    
    local args=(group delete --name "${RESOURCE_GROUP}" --yes)
    if [ "$WAIT_FOR_DELETION" = false ]; then
        args+=(--no-wait)
    fi
    az "${args[@]}"
    
    if [ "$WAIT_FOR_DELETION" = true ]; then
        log_success "Resource group deleted"
    else
        log_success "Resource group deletion initiated (running in background)"
    fi
}

scope=all
while (($# > 0)); do
    case $1 in
        --cluster-only | cluster)
            scope=cluster
            ;;
        --all | all)
            scope=all
            ;;
        --yes)
            ASSUME_YES=true
            ;;
        --wait)
            WAIT_FOR_DELETION=true
            ;;
        -h | --help | help)
            usage
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
    shift
done

if [ "$scope" = cluster ]; then
    delete_cluster_only
else
    delete_resource_group
fi
