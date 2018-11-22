#!/bin/sh
USER="root"
NODE_NAME="peaceflash"
home="/root"

podSubnet=192.168.64.0\\/18
serviceSubnet=192.168.128.0\\/18
clusterDns=${serviceSubnet%.*}.10


sed -i "s/podSubnet: .*\/.*$/podSubnet: ${podSubnet}/g" ./rpm/kube_init_config
sed -i "s/serviceSubnet: .*\/.*$/serviceSubnet: ${serviceSubnet}/g" ./rpm/kube_init_config
sed -i "s/\"Network\": \".*\",$/\"Network\": \"${podSubnet}\",/g" ./rpm/kube-flannel-ds.yaml

systemctl stop firewalld.service
systemctl disable firewalld.service
yum install -y nfs-utils

rm -f /etc/sysctl.d/peaceflash.conf
touch /etc/sysctl.d/peaceflash.conf
cat > /etc/sysctl.d/peaceflash.conf <<EOF
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
vm.max_map_count=231072
EOF
rm -f /etc/sysctl.d/k8s.conf
touch /etc/sysctl.d/k8s.conf
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
vm.swappiness=0
EOF

#加载br_netfilter
modprobe br_netfilter
echo "modprobe br_netfilter" >> /etc/rc.local


sysctl -p /etc/sysctl.d/peaceflash.conf
sysctl -p /etc/sysctl.d/k8s.conf



#禁用SELINUX
setenforce 0
sed -i 's/^SELINUX=enforcing/SELINUX=disable/g' /etc/selinux/config
#关闭系统的Swap
swapoff -a
#注释掉 SWAP 的自动挂载
sed -i '/^[^#].*swap/s/^/#/' /etc/fstab



#安装docker
systemctl stop docker
#yum remove -y docker
#判断宿主机操作系统
#yum install -y docker


if !(grep -q "\-\-selinux\-enabled=false" /etc/sysconfig/docker)
then
        sed -i 's/\-\-selinux\-enabled/\-\-selinux\-enabled=false/g' /etc/sysconfig/docker
fi
if !(grep -q "DOCKER_STORAGE_OPTIONS= \-s overlay" /etc/sysconfig/docker-storage)
then
        sed -i 's/DOCKER_STORAGE_OPTIONS=/DOCKER_STORAGE_OPTIONS= \-s overlay/g' /etc/sysconfig/docker-storage
fi


systemctl start docker
systemctl enable docker


cat > /etc/docker/daemon.json <<EOF
{
    "registry-mirrors": ["https://u10rmlxu.mirror.aliyuncs.com"],
    "graph": "/var/lib/docker"
}
EOF

systemctl daemon-reload
systemctl restart docker

#安装依赖包
yum install -y epel-release
yum install -y yum-utils device-mapper-persistent-data lvm2 net-tools conntrack-tools wget





yum install -y ./rpm/*rpm
systemctl enable kubelet

if !(grep -q "KUBELET_ALIYUN_ARGS" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf)
then
        echo "not exsisted string"
        sed -i '/^ExecStart=$/i\Environment="KUBELET_ALIYUN_ARGS=--pod-infra-container-image=registry.cn-hangzhou.aliyuncs.com/peaceflash/pause-amd64:3.0"' /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
        sed -i 's/^ExecStart=\/.*$/& \$KUBELET_ALIYUN_ARGS'/g /etc/systemd/system/kubelet.service.d/10-kubeadm.conf
fi



sed -i "s/\-\-cluster\-dns=.* \-/\-\-cluster\-dns=${clusterDns} \-/g" /etc/systemd/system/kubelet.service.d/10-kubeadm.conf




systemctl daemon-reload
systemctl restart kubelet

kubeadm reset
mkdir ${home}/${USER}
touch ${home}/${USER}/master_info


export KUBE_REPO_PREFIX="registry.cn-hangzhou.aliyuncs.com/peaceflash"
export KUBE_ETCD_IMAGE="registry.cn-hangzhou.aliyuncs.com/peaceflash/etcd-amd64:3.0.17"



kubeadm init --config ./rpm/kube_init_config > ${home}/${USER}/master_info

echo "kubenetes init successed!"
mkdir ~/.kube
cp /etc/kubernetes/admin.conf ~/.kube/config


kubectl create -f ./rpm/kube-flannel-rbac.yaml
kubectl create -f ./rpm/kube-flannel-ds.yaml

#设置master为不可调度
kubectl taint nodes $NODE_NAME node-role.kubernetes.io/master:NoSchedule-


#解除配置，设置master可以被调度运行pod
#kubectl taint nodes --all node-role.kubernetes.io/master-


#修改K8S中NodePort方式暴露服务的端口的默认范围
grep -q "service-node-port-range=1-65535" /etc/kubernetes/manifests/kube-apiserver.yaml || \
sed -i '/\- \-\-allow\-privileged=true/a\    \- \-\-service\-node\-port\-range=1\-65535' /etc/kubernetes/manifests/kube-apiserver.yaml

sed -i '/\- \-\-allow\-privileged=true/a\    \- \-\-service\-node\-port\-range=1\-65535' /etc/kubernetes/manifests/kube-apiserver.yaml
