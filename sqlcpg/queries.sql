-- name: GetUser :one
SELECT * FROM sys_user WHERE id = $1;