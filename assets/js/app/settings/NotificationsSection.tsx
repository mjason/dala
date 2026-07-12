import React, { useState } from "react";
import { useI18n } from "../i18n";
import { notificationsEnabled, setNotificationsEnabled } from "../notifyPrefs";
import ToggleRow from "./ToggleRow";

/** Master switch for agent system notifications (native/web/toast alike). */
export default function NotificationsSection() {
  const { t } = useI18n();
  const [enabled, setEnabled] = useState(notificationsEnabled);

  return (
    <div className="mt-6 space-y-3 border-t border-line pt-5">
      <div className="text-[13px] font-medium text-fg">{t("notificationsSection")}</div>
      <ToggleRow
        id="notifications-toggle"
        label={t("notificationsToggle")}
        checked={enabled}
        onChange={(v) => {
          setNotificationsEnabled(v);
          setEnabled(v);
        }}
      />
    </div>
  );
}
