//! DNS is sent over the selected Hermes tunnel, never the OS resolver.
use crate::Result;
use atrust_auth::DnsServers;
use atrust_client::AtrustClient;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
const DNS: &str = "hermes_dns_failed";
pub async fn resolve(
    client: &AtrustClient,
    servers: &DnsServers,
    host: &str,
) -> Result<Vec<IpAddr>> {
    let server = servers
        .primary
        .as_deref()
        .or(servers.secondary.as_deref())
        .ok_or(DNS)?;
    let server: IpAddr = server.parse().map_err(|_| DNS)?;
    let mut addresses = Vec::new();
    for kind in [1u16, 28u16] {
        let id = rand::random::<u16>();
        let query = query(host, kind, id)?;
        let mut tunnel = client
            .dial_tcp(&server.to_string(), 53)
            .await
            .map_err(|_| DNS)?
            .tunnel;
        tunnel
            .write_all(&(query.len() as u16).to_be_bytes())
            .await
            .map_err(|_| DNS)?;
        tunnel.write_all(&query).await.map_err(|_| DNS)?;
        tunnel.flush().await.map_err(|_| DNS)?;
        let length = tunnel.read_u16().await.map_err(|_| DNS)? as usize;
        if !(12..=16384).contains(&length) {
            return Err(DNS);
        }
        let mut reply = vec![0u8; length];
        tunnel.read_exact(&mut reply).await.map_err(|_| DNS)?;
        addresses.extend(parse(&reply, &query, id)?);
    }
    Ok(addresses)
}
fn query(host: &str, kind: u16, id: u16) -> Result<Vec<u8>> {
    let mut value = Vec::from(id.to_be_bytes());
    value.extend_from_slice(&[1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    for label in host.split('.') {
        if label.is_empty() || label.len() > 63 {
            return Err(DNS);
        }
        value.push(label.len() as u8);
        value.extend_from_slice(label.as_bytes());
    }
    value.push(0);
    value.extend_from_slice(&kind.to_be_bytes());
    value.extend_from_slice(&1u16.to_be_bytes());
    Ok(value)
}
fn word(value: &[u8], offset: usize) -> Result<u16> {
    value
        .get(offset..offset + 2)
        .map(|b| u16::from_be_bytes([b[0], b[1]]))
        .ok_or(DNS)
}
fn name(value: &[u8], start: usize) -> Result<(String, usize)> {
    let mut offset = start;
    let mut end = None;
    let mut labels = Vec::new();
    let mut visited = std::collections::HashSet::new();
    for _ in 0..128 {
        if !visited.insert(offset) {
            return Err(DNS);
        }
        let len = *value.get(offset).ok_or(DNS)?;
        if len == 0 {
            let name = labels.join(".");
            if name.len() > 253 {
                return Err(DNS);
            }
            return Ok((name, end.unwrap_or(offset + 1)));
        }
        if len & 0xc0 == 0xc0 {
            let pointer = (word(value, offset)? & 0x3fff) as usize;
            if pointer >= value.len() {
                return Err(DNS);
            }
            end.get_or_insert(offset + 2);
            offset = pointer;
            continue;
        }
        if len > 63 {
            return Err(DNS);
        }
        let label = value
            .get(offset + 1..offset + 1 + len as usize)
            .ok_or(DNS)?;
        if !label.is_ascii() {
            return Err(DNS);
        }
        labels.push(
            std::str::from_utf8(label)
                .map_err(|_| DNS)?
                .to_ascii_lowercase(),
        );
        offset += 1 + len as usize;
    }
    Err(DNS)
}
fn parse(value: &[u8], query: &[u8], id: u16) -> Result<Vec<IpAddr>> {
    if word(value, 0)? != id
        || word(value, 2)? & 0x820f != 0x8000
        || word(value, 4)? != 1
        || value.get(12..query.len()) != query.get(12..)
    {
        return Err(DNS);
    }
    let count = word(value, 6)? as usize;
    if count > 128 {
        return Err(DNS);
    }
    let (question, _) = name(query, 12)?;
    let mut offset = query.len();
    let mut aliases = Vec::new();
    let mut addresses = Vec::new();
    for _ in 0..count {
        let (owner, next) = name(value, offset)?;
        offset = next;
        let kind = word(value, offset)?;
        let class = word(value, offset + 2)?;
        let length = word(value, offset + 8)? as usize;
        offset += 10;
        let data = value.get(offset..offset + length).ok_or(DNS)?;
        if class == 1 {
            if kind == 1 && length == 4 {
                addresses.push((
                    owner,
                    IpAddr::V4(Ipv4Addr::new(data[0], data[1], data[2], data[3])),
                ));
            } else if kind == 28 && length == 16 {
                addresses.push((
                    owner,
                    IpAddr::V6(Ipv6Addr::from(<[u8; 16]>::try_from(data).map_err(|_| DNS)?)),
                ));
            } else if kind == 5 {
                let (target, end) = name(value, offset)?;
                if end != offset + length {
                    return Err(DNS);
                }
                aliases.push((owner, target));
            }
        }
        offset += length;
    }
    let mut permitted = std::collections::HashSet::from([question]);
    for _ in 0..16 {
        let previous = permitted.len();
        for (owner, target) in &aliases {
            if permitted.contains(owner) {
                permitted.insert(target.clone());
            }
        }
        if permitted.len() == previous {
            break;
        }
    }
    Ok(addresses
        .into_iter()
        .filter_map(|(owner, ip)| permitted.contains(&owner).then_some(ip))
        .collect())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn bounded_dns_parsing_requires_matching_transaction_and_question() {
        let q = query("synthetic.invalid", 1, 42).unwrap();
        let mut response = q.clone();
        response[2] = 0x81;
        response[3] = 0x80;
        response[7] = 1;
        response.extend_from_slice(&[0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 192, 0, 2, 7]);
        assert_eq!(
            parse(&response, &q, 42).unwrap(),
            vec!["192.0.2.7".parse::<IpAddr>().unwrap()]
        );
        assert!(parse(&response, &q, 43).is_err());
        response[3] = 0x83;
        assert!(parse(&response, &q, 42).is_err());
    }
}
