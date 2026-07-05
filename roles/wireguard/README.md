# wireguard role — location-aware auto-VPN

NetworkManager-native WireGuard (NM 1.46 + the in-kernel module — **no extra
packages**). An NM dispatcher script brings the tunnel **up when away** from the
home network and **down at home**, decided by the **default gateway's MAC**.

Two client connections are used so you can switch easily from the network applet:

| Connection      | Tunnel | Role |
|-----------------|--------|------|
| `wg-home-full`  | full   | default brought up automatically when away (all traffic via home) |
| `wg-home-split` | split  | only the home subnet via the VPN; connect it by hand when preferred |

The dispatcher respects a manual choice: when away it only starts `wg-home-full`
if **no** managed WG connection is already active, so a manual switch to split
sticks until you go home (where everything is dropped).

## One-time setup (the configs are secrets — never committed)

1. Generate the two client configs on the home WG server (a full-tunnel and a
   split-tunnel peer for this laptop).
2. Import them with **exactly these names** (the connection name comes from the
   file name):

   ```sh
   sudo nmcli connection import type wireguard file wg-home-full.conf
   sudo nmcli connection import type wireguard file wg-home-split.conf
   ```

3. Re-run the playbook. It deploys the dispatcher and sets both connections to
   `autoconnect no` (the dispatcher controls activation).

The private keys live only in NetworkManager's system-connection files
(`/etc/NetworkManager/system-connections/*.nmconnection`, root-only) — not here.

## Configuration

- `wg_home_gateway_macs` (host_vars): trusted home gateway MAC(s). Add the AP's
  gateway MAC too if it routes its own subnet (not in bridge mode).
- `wireguard_auto_connection` (default `wg-home-full`): the tunnel started when away.

## Manual use

Click the connection in the network applet to connect/disconnect or switch
full/split at any time. Reaching home drops the tunnel automatically.

## Testing

Tether to a phone hotspot (or any non-home network): `wg-home-full` should come
up within a few seconds. Reconnect to the home network: the tunnel drops.
Check with `nmcli connection show --active`.

## Debugging

The dispatcher is deployed to `/etc/NetworkManager/dispatcher.d/50-wg-autovpn`.
It produces no log output of its own; if it doesn't behave:

```sh
journalctl -u NetworkManager-dispatcher -e     # script errors / exit codes
nmcli connection show --active                 # what is actually up
ip route show default && ip neigh              # the gateway MAC being compared
```

Run it by hand to test the decision logic (it reads the interface + action):
`sudo /etc/NetworkManager/dispatcher.d/50-wg-autovpn eth0 up`.
