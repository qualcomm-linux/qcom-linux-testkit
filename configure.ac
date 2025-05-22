AC_INIT([qcom-linux-testkit], [1.0])
AM_INIT_AUTOMAKE([-Wall -Werror foreign subdir-objects])
AC_PROG_CC
AC_PROG_INSTALL

# Define where to install shell scripts
AC_SUBST([scriptdir], ['${datarootdir}/qcom-linux-testkit'])

# Generate Makefile for the following directories
AC_CONFIG_FILES([
    Makefile
    Runner/Makefile
    Runner/utils/Makefile
    Runner/suites/Makefile
    Runner/suites/Kernel/Makefile
    Runner/suites/Kernel/FunctionalArea/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/adsp_remoteproc/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/Buses/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/BWMON/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/cdsp_remoteproc/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/CPUFreq_Validation/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/GIC/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/hotplug/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/Interrupts/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/iommu/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/IPA/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/IPCC/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/irq/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/kaslr/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/MEMLAT/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/pinctrl/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/qcrypto/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/Reboot_health_check/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/remoteproc/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/RMNET/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/rngtest/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/smmu/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/storage/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/Timer/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/watchdog/Makefile
    Runner/suites/Kernel/FunctionalArea/baseport/wpss_remoteproc/Makefile
    Runner/suites/Multimedia/Makefile
    Runner/suites/Multimedia/DSP_AudioPD/Makefile
    Runner/suites/Multimedia/Graphics/Makefile
    Runner/suites/Multimedia/Video/Makefile
    Runner/suites/Multimedia/Video/iris_v4l2_video_decode/Makefile
    Runner/suites/Multimedia/Video/iris_v4l2_video_encode/Makefile
])

AC_OUTPUT
