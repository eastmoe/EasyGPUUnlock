/* SPDX-License-Identifier: GPL-2.0-only */
#pragma once
#define EGU_VERSION 2u
#define EGU_ARCH_AMPERE 1u
#define EGU_ARCH_ADA 2u
#define EGU_ALLOW_EXPERIMENTAL 1u
#define EGU_ADA_MARKER 0x67b00001u
#define EGU_ADA_READOUT_MASK 0x07ffffffu
#define EGU_ACK 0x45475531u
#define EGU_DIAG CTL_CODE(FILE_DEVICE_UNKNOWN,0x800,METHOD_BUFFERED,FILE_READ_DATA)
#define EGU_RUN CTL_CODE(FILE_DEVICE_UNKNOWN,0x801,METHOD_BUFFERED,FILE_READ_DATA|FILE_WRITE_DATA)
#define EGU_GUID_VALUE {0xd7a33965,0x6ec9,0x49d0,{0x9b,0x2d,0x7a,0x6c,0xab,0x52,0x7d,0x12}}
typedef struct { unsigned long version,ack,flags,reserved; } EGU_INPUT;
typedef struct {
    unsigned long version,device,state;
    long result;
    unsigned long retained,fault,started,flr_complete,safe_to_restore;
    unsigned long ss0,ss1,wpr_hi,reset_supported;
    unsigned long architecture,payload_marker,permissions_verified;
    unsigned long readout_before_flr,readout_after_flr;
    char log[16384];
} EGU_REPORT;
/* state: 0=fresh, 1=selectors+FLR+cleanup verified, 2=failed.
 * safe_to_restore is only valid after a completed RUN. No CUDA claim. */
