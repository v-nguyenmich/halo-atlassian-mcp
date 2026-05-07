"""Entry point: `python -m halo_mcp_atlassian` or `halo-mcp-atlassian`."""

from .server import build_server


def main() -> None:
    server = build_server()
    server.run()


if __name__ == "__main__":
    main()
