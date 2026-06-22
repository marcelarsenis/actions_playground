"""Print the first 100 prime numbers, one per line."""


def is_prime(number: int) -> bool:
    if number < 2:
        return False

    divisor = 2
    while divisor * divisor <= number:
        if number % divisor == 0:
            return False
        divisor += 1

    return True


def main() -> None:
    count = 0
    candidate = 2

    while count < 100:
        if is_prime(candidate):
            print(candidate)
            count += 1
        candidate += 1


if __name__ == "__main__":
    main()
