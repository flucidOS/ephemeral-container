# /usr/share/ephemeral-container/ec-profile.sh
# Interactive shell profile inside the FlucidOS 1:1 Ephemeral Container

touch /run/.ec-session
rm -f /var/tmp/.ec-commit

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PS1="\[\033[1;36m\][ec:1:1-clone \W]\[\033[0m\]# "

alias exit='echo "Use \"ec exit\" to seal & save changes, or \"ec abort\" to discard."'

mkdir -p /tmp/ec-work
cd /tmp/ec-work

echo "--------------------------------------------------------------------------------"
echo " FlucidOS Ephemeral Container (1:1 System Clone)"
echo " Target Deployment : ${TARGET_COMMIT:-local}"
echo " Target Kernel ABI : ${KVER:-unknown}"
echo " Working Directory : /tmp/ec-work (discarded on seal)"
echo ""
echo " Install Locations :"
echo "   * Kernel Modules : /usr/lib/modules/${KVER}/extra/"
echo "   * Modprobe Rules : /usr/lib/modprobe.d/"
echo "   * System Binaries: /usr/local/bin/ or /usr/local/lib/"
echo ""
echo " Commands :"
echo "   * ec exit        : Sign modules, run unified depmod, stage & truncate"
echo "   * ec abort       : Discard all changes & truncate immediately"
echo "--------------------------------------------------------------------------------"
