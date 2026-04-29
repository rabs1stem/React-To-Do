from tests.conftest import client


def test_create_user():
    response = client.post(
        "/users/", json={"email": "test@test.com", "password": "123456"}
    )
    assert response.status_code == 200
