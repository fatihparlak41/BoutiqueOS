import type { TeamActionState } from "@/lib/team/action-state";

/**
 * Team action feedback.
 *
 * The third branch is the point of this component: when the deployment has no
 * privileged Auth key, the invitation row is real but no email went out. That is
 * reported as CONFIGURATION_REQUIRED with the link to hand over, never as plain
 * success — a colleague would otherwise be left waiting for mail that never comes.
 */
export function TeamMessage({ state, successText }: { state: TeamActionState; successText?: string }) {
  if (state.error) {
    return (
      <div className="space-y-2">
        <p role="alert" className="rounded border border-danger/30 bg-danger-muted/50 px-3 py-2 text-sm leading-relaxed text-danger">
          {state.error}
        </p>
        {state.inviteUrl ? <InviteLink url={state.inviteUrl} /> : null}
      </div>
    );
  }

  if (state.ok && state.configurationRequired) {
    return (
      <div className="space-y-2">
        <p
          role="status"
          className="rounded border border-warning/30 bg-warning-muted/60 px-3 py-2 text-xs leading-relaxed text-text-secondary"
        >
          <span className="font-medium text-ink">CONFIGURATION_REQUIRED</span> — davet oluşturuldu, ancak
          bu ortamda e-posta gönderimi yapılandırılmamış. Aşağıdaki bağlantıyı çalışana kendiniz
          iletebilirsiniz.
        </p>
        {state.inviteUrl ? <InviteLink url={state.inviteUrl} /> : null}
      </div>
    );
  }

  if (state.ok && successText) {
    return (
      <p role="status" className="rounded border border-success/25 bg-success-muted px-3 py-2 text-sm text-success">
        {successText}
      </p>
    );
  }

  return null;
}

function InviteLink({ url }: { url: string }) {
  return (
    <p className="break-all rounded border border-border bg-surface px-3 py-2 text-2xs text-text-secondary" data-numeric>
      {url}
    </p>
  );
}
