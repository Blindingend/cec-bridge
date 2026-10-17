.class public Lio/github/cecbridge/MainActivity;
.super Landroid/app/Activity;
.source "MainActivity.java"

.method public constructor <init>()V
    .locals 0
    invoke-direct {p0}, Landroid/app/Activity;-><init>()V
    return-void
.end method

.method protected onCreate(Landroid/os/Bundle;)V
    .locals 0
    invoke-super {p0, p1}, Landroid/app/Activity;->onCreate(Landroid/os/Bundle;)V
    invoke-static {p0}, Lio/github/cecbridge/TvRunner;->run(Landroid/content/Context;)V
    invoke-static {p0}, Lio/github/cecbridge/TvRunner;->schedule(Landroid/content/Context;)V
    invoke-virtual {p0}, Lio/github/cecbridge/MainActivity;->finish()V
    return-void
.end method
