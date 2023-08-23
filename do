#!/bin/bash
set -euo pipefail

export TALOSCONFIG=$PWD/talosconfig.yml
export KUBECONFIG=$PWD/kubeconfig.yml

function step {
  echo "### $* ###"
}

function init {
  step 'terraform init'
  terraform init -lockfile=readonly
}

function plan {
  step 'terraform plan'
  terraform plan -out=tfplan
}

function apply {
  step 'terraform apply'
  terraform apply tfplan
  terraform output -raw talosconfig >talosconfig.yml
  terraform output -raw kubeconfig >kubeconfig.yml
  health
}

function health {
  step 'talosctl health'
  local controllers="$(terraform output -raw controllers)"
  local workers="$(terraform output -raw workers)"
  local c0="$(echo $controllers | cut -d , -f 1)"
  talosctl -e $c0 -n $c0 \
    health \
    --control-plane-nodes $controllers \
    --worker-nodes $workers
}

function upgrade {
  step 'talosctl upgrade'
  local controllers=($(terraform output -raw controllers | tr ',' ' '))
  local workers=($(terraform output -raw workers | tr ',' ' '))
  for n in "${controllers[@]}" "${workers[@]}"; do
    talosctl -e $n -n $n upgrade --preserve --wait
  done
}

function destroy {
  terraform destroy -auto-approve
}

case $1 in
  init)
    init
    ;;
  plan)
    plan
    ;;
  apply)
    apply
    ;;
  plan-apply)
    plan
    apply
    upgrade
    ;;
  health)
    health
    ;;
  destroy)
    destroy
    ;;
  *)
    echo $"Usage: $0 {init|plan|apply|plan-apply|health}"
    exit 1
    ;;
esac
