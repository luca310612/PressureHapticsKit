"""Closed-loop FlyGym/MaleCNS experiments."""


def main() -> None:
    """Delegate to the application orchestrator."""
    from gnat.main import main as application_main

    application_main()
