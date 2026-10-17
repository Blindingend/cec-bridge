.class public Lio/github/cecbridge/BootReceiver;
.super Landroid/content/BroadcastReceiver;
.source "BootReceiver.java"

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Landroid/content/BroadcastReceiver;-><init>()V
    return-void
.end method

.method public onReceive(Landroid/content/Context;Landroid/content/Intent;)V
    .locals 0
    invoke-static {p1}, Lio/github/cecbridge/TvRunner;->run(Landroid/content/Context;)V
    invoke-static {p1}, Lio/github/cecbridge/TvRunner;->schedule(Landroid/content/Context;)V
    return-void
.end method
