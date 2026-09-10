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
        <p role="alert" className="border-l-2 border-danger bg-panel px-3 py-2 text-sm leading-relaxed text-danger">
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
          className="border-l-2 border-line-strong bg-panel px-3 py-2 text-xs leading-relaxed text-ink-70"
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
      <p role="status" className="border-l-2 border-accent bg-accent-soft px-3 py-2 text-sm text-accent">
        {successText}
      </p>
    );
  }

  return null;
}

function InviteLink({ url }: { url: string }) {
  return (
    <p className="break-all border border-line bg-paper px-3 py-2 text-2xs text-ink-70" data-numeric>
      {url}
    </p>
  );
}
