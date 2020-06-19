#!/usr/bin/env bash

set -euo pipefail

apt update
apt install -y python-pip cpanminus
pip install ansible
ansible-playbook ansible.yml