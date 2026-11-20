/* Android's fixed accounts, which joe Linux does not have: every account is
 * in /etc/passwd and /etc/group. Replaces the table bionic generates from
 * system/core's android_filesystem_config.h. */
#pragma once

struct android_id_info {
  const char name[17];
  unsigned aid;
};

static const struct android_id_info android_ids[] = {};

#define android_id_count 0
