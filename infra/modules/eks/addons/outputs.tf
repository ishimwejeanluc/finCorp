output "installed" {
  description = "Add-ons installed by this module (informational)."
  value       = [aws_eks_addon.vpc_cni.addon_name, aws_eks_addon.kube_proxy.addon_name, aws_eks_addon.coredns.addon_name]
}
