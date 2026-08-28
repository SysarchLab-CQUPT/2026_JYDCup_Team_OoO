import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser(description="Pack a binary into readmemh 64-bit little-endian words")
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    data = args.input.read_bytes()
    lines = []
    for offset in range(0, len(data), 8):
        chunk = data[offset : offset + 8].ljust(8, b"\x00")
        lines.append(f"{int.from_bytes(chunk, 'little'):016x}")
    args.output.write_text("\n".join(lines) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()

