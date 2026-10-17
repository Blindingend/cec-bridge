.class public Lio/github/cecbridge/WatchdogJobService;
.super Landroid/app/job/JobService;
.source "WatchdogJobService.java"

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Landroid/app/job/JobService;-><init>()V
    return-void
.end method

.method public onStartJob(Landroid/app/job/JobParameters;)Z
    .locals 3
    invoke-virtual {p0}, Lio/github/cecbridge/WatchdogJobService;->getApplicationContext()Landroid/content/Context;
    move-result-object v0
    invoke-static {v0}, Lio/github/cecbridge/TvRunner;->run(Landroid/content/Context;)V
    invoke-virtual {p1}, Landroid/app/job/JobParameters;->getJobId()I
    move-result v1
    const/16 v2, 0x1093
    if-ne v1, v2, :cond_0
    const/16 v1, 0x1094
    goto :goto_0

    :cond_0
    const/16 v1, 0x1093

    :goto_0
    invoke-static {v0, v1}, Lio/github/cecbridge/TvRunner;->scheduleBootJob(Landroid/content/Context;I)V
    const/4 v0, 0x0
    return v0
.end method

.method public onStopJob(Landroid/app/job/JobParameters;)Z
    .locals 1
    const/4 v0, 0x0
    return v0
.end method
