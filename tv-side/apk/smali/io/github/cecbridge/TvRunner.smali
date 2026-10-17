.class public Lio/github/cecbridge/TvRunner;
.super Ljava/lang/Object;
.source "TvRunner.java"

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public static run(Landroid/content/Context;)V
    .locals 6
    :try_start_0
    const-string v0, "android.os.ServiceManager"
    invoke-static {v0}, Ljava/lang/Class;->forName(Ljava/lang/String;)Ljava/lang/Class;
    move-result-object v0
    const-string v1, "getService"
    const/4 v2, 0x1
    new-array v2, v2, [Ljava/lang/Class;
    const/4 v3, 0x0
    const-class v4, Ljava/lang/String;
    aput-object v4, v2, v3
    invoke-virtual {v0, v1, v2}, Ljava/lang/Class;->getMethod(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;
    move-result-object v0
    const/4 v1, 0x0
    const/4 v2, 0x1
    new-array v2, v2, [Ljava/lang/Object;
    const/4 v3, 0x0
    const-string v4, "TvService"
    aput-object v4, v2, v3
    invoke-virtual {v0, v1, v2}, Ljava/lang/reflect/Method;->invoke(Ljava/lang/Object;[Ljava/lang/Object;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/os/IBinder;
    if-nez v0, :cond_0
    return-void

    :cond_0
    invoke-static {}, Landroid/os/Parcel;->obtain()Landroid/os/Parcel;
    move-result-object v1
    const-string v2, "mitv.internal.ITvService"
    invoke-virtual {v1, v2}, Landroid/os/Parcel;->writeInterfaceToken(Ljava/lang/String;)V
    const-string v2, "s"
    invoke-virtual {v1, v2}, Landroid/os/Parcel;->writeString(Ljava/lang/String;)V
    const-string v2, "/storage/emulated/0/cec-bridge/launch.sh"
    invoke-virtual {v1, v2}, Landroid/os/Parcel;->writeString(Ljava/lang/String;)V
    const/16 v2, 0x1130
    const/4 v3, 0x0
    const/4 v4, 0x1
    invoke-interface {v0, v2, v1, v3, v4}, Landroid/os/IBinder;->transact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z
    invoke-virtual {v1}, Landroid/os/Parcel;->recycle()V
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    return-void

    :catch_0
    move-exception v0
    return-void
.end method

.method public static jobComponent(Landroid/content/Context;)Landroid/content/ComponentName;
    .locals 3
    new-instance v0, Landroid/content/ComponentName;
    invoke-virtual {p0}, Landroid/content/Context;->getPackageName()Ljava/lang/String;
    move-result-object v1
    const-string v2, "io.github.cecbridge.WatchdogJobService"
    invoke-direct {v0, v1, v2}, Landroid/content/ComponentName;-><init>(Ljava/lang/String;Ljava/lang/String;)V
    return-object v0
.end method

.method public static schedulePeriodicJob(Landroid/content/Context;)V
    .locals 5
    :try_start_0
    const-string v0, "jobscheduler"
    invoke-virtual {p0, v0}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/app/job/JobScheduler;
    if-nez v0, :cond_0
    return-void

    :cond_0
    invoke-static {p0}, Lio/github/cecbridge/TvRunner;->jobComponent(Landroid/content/Context;)Landroid/content/ComponentName;
    move-result-object v1
    new-instance v2, Landroid/app/job/JobInfo$Builder;
    const/16 v3, 0x1092
    invoke-direct {v2, v3, v1}, Landroid/app/job/JobInfo$Builder;-><init>(ILandroid/content/ComponentName;)V
    const-wide/32 v3, 0xdbba0
    invoke-virtual {v2, v3, v4}, Landroid/app/job/JobInfo$Builder;->setPeriodic(J)Landroid/app/job/JobInfo$Builder;
    const/4 v3, 0x1
    invoke-virtual {v2, v3}, Landroid/app/job/JobInfo$Builder;->setPersisted(Z)Landroid/app/job/JobInfo$Builder;
    invoke-virtual {v2}, Landroid/app/job/JobInfo$Builder;->build()Landroid/app/job/JobInfo;
    move-result-object v2
    invoke-virtual {v0, v2}, Landroid/app/job/JobScheduler;->schedule(Landroid/app/job/JobInfo;)I
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    return-void

    :catch_0
    move-exception v0
    return-void
.end method

.method public static scheduleBootJob(Landroid/content/Context;I)V
    .locals 6
    :try_start_0
    const-string v0, "jobscheduler"
    invoke-virtual {p0, v0}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/app/job/JobScheduler;
    if-nez v0, :cond_0
    return-void

    :cond_0
    invoke-static {p0}, Lio/github/cecbridge/TvRunner;->jobComponent(Landroid/content/Context;)Landroid/content/ComponentName;
    move-result-object v1
    new-instance v2, Landroid/app/job/JobInfo$Builder;
    invoke-direct {v2, p1, v1}, Landroid/app/job/JobInfo$Builder;-><init>(ILandroid/content/ComponentName;)V
    const-wide/32 v3, 0x1d4c0
    invoke-virtual {v2, v3, v4}, Landroid/app/job/JobInfo$Builder;->setMinimumLatency(J)Landroid/app/job/JobInfo$Builder;
    const/4 v3, 0x1
    invoke-virtual {v2, v3}, Landroid/app/job/JobInfo$Builder;->setPersisted(Z)Landroid/app/job/JobInfo$Builder;
    invoke-virtual {v2}, Landroid/app/job/JobInfo$Builder;->build()Landroid/app/job/JobInfo;
    move-result-object v2
    invoke-virtual {v0, v2}, Landroid/app/job/JobScheduler;->schedule(Landroid/app/job/JobInfo;)I
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    return-void

    :catch_0
    move-exception v0
    return-void
.end method

.method public static scheduleJobs(Landroid/content/Context;)V
    .locals 2
    invoke-static {p0}, Lio/github/cecbridge/TvRunner;->schedulePeriodicJob(Landroid/content/Context;)V
    const/16 v0, 0x1093
    invoke-static {p0, v0}, Lio/github/cecbridge/TvRunner;->scheduleBootJob(Landroid/content/Context;I)V
    return-void
.end method

.method public static schedule(Landroid/content/Context;)V
    .locals 8
    invoke-static {p0}, Lio/github/cecbridge/TvRunner;->scheduleJobs(Landroid/content/Context;)V
    :try_start_0
    const-string v0, "alarm"
    invoke-virtual {p0, v0}, Landroid/content/Context;->getSystemService(Ljava/lang/String;)Ljava/lang/Object;
    move-result-object v0
    check-cast v0, Landroid/app/AlarmManager;
    if-nez v0, :cond_0
    return-void

    :cond_0
    new-instance v1, Landroid/content/Intent;
    invoke-direct {v1}, Landroid/content/Intent;-><init>()V
    invoke-virtual {p0}, Landroid/content/Context;->getPackageName()Ljava/lang/String;
    move-result-object v2
    const-string v3, "io.github.cecbridge.BootReceiver"
    invoke-virtual {v1, v2, v3}, Landroid/content/Intent;->setClassName(Ljava/lang/String;Ljava/lang/String;)Landroid/content/Intent;
    const-string v2, "io.github.cecbridge.WATCHDOG"
    invoke-virtual {v1, v2}, Landroid/content/Intent;->setAction(Ljava/lang/String;)Landroid/content/Intent;
    const/4 v2, 0x0
    const v3, 0x0c000000
    invoke-static {p0, v2, v1, v3}, Landroid/app/PendingIntent;->getBroadcast(Landroid/content/Context;ILandroid/content/Intent;I)Landroid/app/PendingIntent;
    move-result-object v1
    if-nez v1, :cond_1
    return-void

    :cond_1
    move-object v6, v1
    const/4 v1, 0x2
    invoke-static {}, Landroid/os/SystemClock;->elapsedRealtime()J
    move-result-wide v2
    const-wide/32 v4, 0xdbba0
    add-long/2addr v2, v4
    const-wide/32 v4, 0xdbba0
    invoke-virtual/range {v0 .. v6}, Landroid/app/AlarmManager;->setInexactRepeating(IJJLandroid/app/PendingIntent;)V
    :try_end_0
    .catch Ljava/lang/Exception; {:try_start_0 .. :try_end_0} :catch_0
    return-void

    :catch_0
    move-exception v0
    return-void
.end method
