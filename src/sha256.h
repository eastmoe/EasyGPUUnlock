#pragma once
#include <ntddk.h>
typedef SIZE_T UINTN;
VOID GuSha256(const VOID *,UINTN,UINT8[32]);
BOOLEAN GuHashMatches(const VOID *,UINTN,const char *);
