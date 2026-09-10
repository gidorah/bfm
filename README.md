# BFM

BFM (Bidirectional Failover Manager) is a Failover manager for PostgreSQL with a lot of advanced capabilities. 

It has many advantages over diferrent failover managers. 

1. Security: You can choose secure communication (TLS support) between failover manager and postgresql instances, and also between the components of BFM. Also you can encrypt any password within the configuration files.

2. Failover priority: You can give priority for the PostgreSQL instances. Any random master selection is eleminated.  

3. VIP support : You can use virtual ip and transfer virtual ip to new nodes so that your applications does not need any configuration change after the failover.  

4. Self - HA  : You can prefer to use 2 seperate BFM instances to manage the PostgreSQL cluster. If one BFM is down the other will take control.

5. WEB UI : You can manage and monitor your PostgreSQL-Cluster with modern web interface, also you can use command line tool (bfm_ctl).

## Installation

To install BFM, first add the repository and then install the package:

```bash
sudo dnf install -y https://nexus.bisoft.com.tr/repository/bfm-yum/repo/bisoft-repo-1.0-1.noarch.rpm
sudo dnf install -y bfm-rpm-package


sudo yum install -y https://nexus.bisoft.com.tr/repository/bfm-yum/repo/bisoft-repo-1.0-1.noarch.rpm
sudo yum install -y bfm-rpm-package

## Local development

For a reproducible local run (isolated config, state and logs under `_work-tmp/local/`, BFM on port 9995 so it never clashes with BFM4Patroni on 9994):

```bash
just local-prepare   # generate local config + state from dev/local/ templates
just build           # build the app jar
just run-local       # ...or F5 "BFM — local cluster" in VS Code
```

See [dev/local/README.md](dev/local/README.md) for the full flow (`local-status` / `local-logs` / `local-reset` / `local-verify`).
