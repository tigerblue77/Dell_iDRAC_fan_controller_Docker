#!/usr/bin/env bats

load '../functions.sh'

# Helper function to test calculate_interpolated_fan_speed
assert_interpolated_fan_speed() {
    local temp=$1
    local lower_threshold=$2
    local upper_threshold=$3
    local min_speed=$4
    local max_speed=$5
    local expected=$6

    run calculate_interpolated_fan_speed "$temp" "$lower_threshold" "$upper_threshold" "$min_speed" "$max_speed"

    if [ "$status" -ne 0 ]; then
        echo "Command failed with exit status $status"
        return 1
    fi

    if [ "$output" -ne "$expected" ]; then
        echo "Assertion failed:"
        echo "Expected: $expected"
        echo "Actual: $output"
        echo "For temperature ${temp}°C (range ${lower_threshold}-${upper_threshold}°C, fan speed ${min_speed}-${max_speed}%)"
        return 1
    fi
}

@test "calculate_interpolated_fan_speed: temperature below threshold" {
    local cpu_temp=50
    local lower_threshold=60
    local upper_threshold=80
    local min_fan_speed=30
    local max_fan_speed=100
    local expected_fan_speed=30

    assert_interpolated_fan_speed $cpu_temp $lower_threshold $upper_threshold $min_fan_speed $max_fan_speed $expected_fan_speed
}

@test "calculate_interpolated_fan_speed: temperature at lower threshold" {
    local cpu_temp=60
    local lower_threshold=60
    local upper_threshold=80
    local min_fan_speed=30
    local max_fan_speed=100
    local expected_fan_speed=30

    assert_interpolated_fan_speed $cpu_temp $lower_threshold $upper_threshold $min_fan_speed $max_fan_speed $expected_fan_speed
}

@test "calculate_interpolated_fan_speed: temperature between thresholds" {
    local cpu_temp=70
    local lower_threshold=60
    local upper_threshold=80
    local min_fan_speed=30
    local max_fan_speed=100
    local expected_fan_speed=65

    assert_interpolated_fan_speed $cpu_temp $lower_threshold $upper_threshold $min_fan_speed $max_fan_speed $expected_fan_speed
}

@test "calculate_interpolated_fan_speed: temperature at upper threshold" {
    local cpu_temp=80
    local lower_threshold=60
    local upper_threshold=80
    local min_fan_speed=30
    local max_fan_speed=100
    local expected_fan_speed=100

    assert_interpolated_fan_speed $cpu_temp $lower_threshold $upper_threshold $min_fan_speed $max_fan_speed $expected_fan_speed
}

@test "calculate_interpolated_fan_speed: temperature above upper threshold" {
    local cpu_temp=90
    local lower_threshold=60
    local upper_threshold=80
    local min_fan_speed=30
    local max_fan_speed=100
    local expected_fan_speed=100

    assert_interpolated_fan_speed $cpu_temp $lower_threshold $upper_threshold $min_fan_speed $max_fan_speed $expected_fan_speed
}

@test "calculate_interpolated_fan_speed: small temperature range" {
    local cpu_temp=65
    local lower_threshold=60
    local upper_threshold=70
    local min_fan_speed=50
    local max_fan_speed=70
    local expected_fan_speed=60

    assert_interpolated_fan_speed $cpu_temp $lower_threshold $upper_threshold $min_fan_speed $max_fan_speed $expected_fan_speed
}

@test "calculate_interpolated_fan_speed: inverted thresholds" {
    local cpu_temp=70
    local lower_threshold=80
    local upper_threshold=60
    local min_fan_speed=30
    local max_fan_speed=100
    local expected_fan_speed=30

    assert_interpolated_fan_speed $cpu_temp $lower_threshold $upper_threshold $min_fan_speed $max_fan_speed $expected_fan_speed
}

@test "calculate_interpolated_fan_speed: multiple temperature points from README" {
    local lower_threshold=30
    local upper_threshold=70
    local min_speed=10
    local max_speed=50

    assert_interpolated_fan_speed 15 $lower_threshold $upper_threshold $min_speed $max_speed 10
    assert_interpolated_fan_speed 30 $lower_threshold $upper_threshold $min_speed $max_speed 10
    assert_interpolated_fan_speed 35 $lower_threshold $upper_threshold $min_speed $max_speed 15
    assert_interpolated_fan_speed 50 $lower_threshold $upper_threshold $min_speed $max_speed 30
    assert_interpolated_fan_speed 69 $lower_threshold $upper_threshold $min_speed $max_speed 49
    assert_interpolated_fan_speed 70 $lower_threshold $upper_threshold $min_speed $max_speed 50
    assert_interpolated_fan_speed 80 $lower_threshold $upper_threshold $min_speed $max_speed 50
}

@test "calculate_interpolated_fan_speed: comprehensive temperature range 0-100" {
    local lower_threshold=20
    local upper_threshold=80
    local min_speed=10
    local max_speed=60

    # Temperatures below lower threshold
    for temp in {0..19}; do
        assert_interpolated_fan_speed "$temp" $lower_threshold $upper_threshold $min_speed $max_speed 10
    done

    # Temperatures at lower threshold
    assert_interpolated_fan_speed 20 $lower_threshold $upper_threshold $min_speed $max_speed 10

    # Temperatures in interpolation range
    assert_interpolated_fan_speed 21 $lower_threshold $upper_threshold $min_speed $max_speed 10
    assert_interpolated_fan_speed 22 $lower_threshold $upper_threshold $min_speed $max_speed 11
    assert_interpolated_fan_speed 23 $lower_threshold $upper_threshold $min_speed $max_speed 12
    assert_interpolated_fan_speed 24 $lower_threshold $upper_threshold $min_speed $max_speed 13
    assert_interpolated_fan_speed 25 $lower_threshold $upper_threshold $min_speed $max_speed 14
    assert_interpolated_fan_speed 26 $lower_threshold $upper_threshold $min_speed $max_speed 15
    assert_interpolated_fan_speed 27 $lower_threshold $upper_threshold $min_speed $max_speed 15
    assert_interpolated_fan_speed 28 $lower_threshold $upper_threshold $min_speed $max_speed 16
    assert_interpolated_fan_speed 29 $lower_threshold $upper_threshold $min_speed $max_speed 17
    assert_interpolated_fan_speed 30 $lower_threshold $upper_threshold $min_speed $max_speed 18
    assert_interpolated_fan_speed 31 $lower_threshold $upper_threshold $min_speed $max_speed 19
    assert_interpolated_fan_speed 32 $lower_threshold $upper_threshold $min_speed $max_speed 20
    assert_interpolated_fan_speed 33 $lower_threshold $upper_threshold $min_speed $max_speed 20
    assert_interpolated_fan_speed 34 $lower_threshold $upper_threshold $min_speed $max_speed 21
    assert_interpolated_fan_speed 35 $lower_threshold $upper_threshold $min_speed $max_speed 22
    assert_interpolated_fan_speed 36 $lower_threshold $upper_threshold $min_speed $max_speed 23
    assert_interpolated_fan_speed 37 $lower_threshold $upper_threshold $min_speed $max_speed 24
    assert_interpolated_fan_speed 38 $lower_threshold $upper_threshold $min_speed $max_speed 25
    assert_interpolated_fan_speed 39 $lower_threshold $upper_threshold $min_speed $max_speed 25
    assert_interpolated_fan_speed 40 $lower_threshold $upper_threshold $min_speed $max_speed 26
    assert_interpolated_fan_speed 41 $lower_threshold $upper_threshold $min_speed $max_speed 27
    assert_interpolated_fan_speed 42 $lower_threshold $upper_threshold $min_speed $max_speed 28
    assert_interpolated_fan_speed 43 $lower_threshold $upper_threshold $min_speed $max_speed 29
    assert_interpolated_fan_speed 44 $lower_threshold $upper_threshold $min_speed $max_speed 30
    assert_interpolated_fan_speed 45 $lower_threshold $upper_threshold $min_speed $max_speed 30
    assert_interpolated_fan_speed 46 $lower_threshold $upper_threshold $min_speed $max_speed 31
    assert_interpolated_fan_speed 47 $lower_threshold $upper_threshold $min_speed $max_speed 32
    assert_interpolated_fan_speed 48 $lower_threshold $upper_threshold $min_speed $max_speed 33
    assert_interpolated_fan_speed 49 $lower_threshold $upper_threshold $min_speed $max_speed 34
    assert_interpolated_fan_speed 50 $lower_threshold $upper_threshold $min_speed $max_speed 35
    assert_interpolated_fan_speed 51 $lower_threshold $upper_threshold $min_speed $max_speed 35
    assert_interpolated_fan_speed 52 $lower_threshold $upper_threshold $min_speed $max_speed 36
    assert_interpolated_fan_speed 53 $lower_threshold $upper_threshold $min_speed $max_speed 37
    assert_interpolated_fan_speed 54 $lower_threshold $upper_threshold $min_speed $max_speed 38
    assert_interpolated_fan_speed 55 $lower_threshold $upper_threshold $min_speed $max_speed 39
    assert_interpolated_fan_speed 56 $lower_threshold $upper_threshold $min_speed $max_speed 40
    assert_interpolated_fan_speed 57 $lower_threshold $upper_threshold $min_speed $max_speed 40
    assert_interpolated_fan_speed 58 $lower_threshold $upper_threshold $min_speed $max_speed 41
    assert_interpolated_fan_speed 59 $lower_threshold $upper_threshold $min_speed $max_speed 42
    assert_interpolated_fan_speed 60 $lower_threshold $upper_threshold $min_speed $max_speed 43
    assert_interpolated_fan_speed 61 $lower_threshold $upper_threshold $min_speed $max_speed 44
    assert_interpolated_fan_speed 62 $lower_threshold $upper_threshold $min_speed $max_speed 45
    assert_interpolated_fan_speed 63 $lower_threshold $upper_threshold $min_speed $max_speed 45
    assert_interpolated_fan_speed 64 $lower_threshold $upper_threshold $min_speed $max_speed 46
    assert_interpolated_fan_speed 65 $lower_threshold $upper_threshold $min_speed $max_speed 47
    assert_interpolated_fan_speed 66 $lower_threshold $upper_threshold $min_speed $max_speed 48
    assert_interpolated_fan_speed 67 $lower_threshold $upper_threshold $min_speed $max_speed 49
    assert_interpolated_fan_speed 68 $lower_threshold $upper_threshold $min_speed $max_speed 50
    assert_interpolated_fan_speed 69 $lower_threshold $upper_threshold $min_speed $max_speed 50
    assert_interpolated_fan_speed 70 $lower_threshold $upper_threshold $min_speed $max_speed 51
    assert_interpolated_fan_speed 71 $lower_threshold $upper_threshold $min_speed $max_speed 52
    assert_interpolated_fan_speed 72 $lower_threshold $upper_threshold $min_speed $max_speed 53
    assert_interpolated_fan_speed 73 $lower_threshold $upper_threshold $min_speed $max_speed 54
    assert_interpolated_fan_speed 74 $lower_threshold $upper_threshold $min_speed $max_speed 55
    assert_interpolated_fan_speed 75 $lower_threshold $upper_threshold $min_speed $max_speed 55
    assert_interpolated_fan_speed 76 $lower_threshold $upper_threshold $min_speed $max_speed 56
    assert_interpolated_fan_speed 77 $lower_threshold $upper_threshold $min_speed $max_speed 57
    assert_interpolated_fan_speed 78 $lower_threshold $upper_threshold $min_speed $max_speed 58
    assert_interpolated_fan_speed 79 $lower_threshold $upper_threshold $min_speed $max_speed 59

    # Temperatures at upper threshold
    assert_interpolated_fan_speed 80 $lower_threshold $upper_threshold $min_speed $max_speed 60

    # Temperatures above upper threshold
    for temp in {81..100}; do
        assert_interpolated_fan_speed "$temp" $lower_threshold $upper_threshold $min_speed $max_speed 60
    done
}
