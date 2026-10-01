import std/unittest
import ic_sqlite

suite "query compiler":
  test "quotes identifiers and preserves SQL parameter order":
    var db: Db
    let compiled = db.table("users")
      .select("id", "name")
      .where("age", ">=", 18'i64)
      .where("active", "=", true)
      .orderBy("id", Desc)
      .limit(20)
      .compile()
    check compiled.isOk
    check compiled.value.sql == "SELECT \"id\", \"name\" FROM \"users\" WHERE \"age\" >= ? AND \"active\" = ? ORDER BY \"id\" DESC LIMIT ?"
    check compiled.value.params.len == 3
    check compiled.value.params[0].intValue == 18
    check compiled.value.params[1].intValue == 1
    check compiled.value.params[2].intValue == 20

  test "rejects invalid identifiers, invalid operations, and negative bounds":
    var db: Db
    check not db.table("users; DROP TABLE users").compile().isOk
    check not db.table("users").where("id", "OR 1=1", 1).compile().isOk
    check not db.table("users").limit(-1).compile().isOk
    check not db.table("users").offset(-1).compile().isOk

  test "compiles NULL predicates without parameters":
    var db: Db
    let compiled = db.table("users").whereNull("deleted_at").whereNotNull("email").compile()
    check compiled.isOk
    check compiled.value.sql == "SELECT * FROM \"users\" WHERE \"deleted_at\" IS NULL AND \"email\" IS NOT NULL"
    check compiled.value.params.len == 0

  test "compiles OR predicates and quoted joins":
    var db: Db
    let compiled = db.table("users", "u")
      .select("u.id", "p.bio")
      .leftJoin("profiles", "p", "u.id", "=", "p.user_id")
      .where("u.active", "=", true)
      .orWhere("u.role", "=", "admin")
      .compile()
    check compiled.isOk
    check compiled.value.sql == "SELECT \"u\".\"id\", \"p\".\"bio\" FROM \"users\" AS \"u\" LEFT JOIN \"profiles\" AS \"p\" ON \"u\".\"id\" = \"p\".\"user_id\" WHERE \"u\".\"active\" = ? OR \"u\".\"role\" = ?"
    check compiled.value.params.len == 2

  test "compiles IN, NOT IN, BETWEEN, and defined empty IN semantics":
    var db: Db
    let compiled = db.table("users").whereIn("id", [1'i64, 2])
      .whereNotIn("role", newSeq[string]())
      .whereBetween("age", 18'i64, 64).compile()
    check compiled.isOk
    check compiled.value.sql == "SELECT * FROM \"users\" WHERE \"id\" IN (?, ?) AND 1 AND \"age\" BETWEEN ? AND ?"
    check compiled.value.params.len == 4
    check db.table("users").whereIn("id", newSeq[int64]()).compile().value.sql == "SELECT * FROM \"users\" WHERE 0"

  test "groups OR conditions without interpolating values":
    var db: Db
    let compiled = db.table("users").where("active", "=", true)
      .whereGroup(proc(b: var PredicateBuilder) =
        b.where("role", "=", "admin")
        b.orWhere("role", "=", "moderator")
      ).compile()
    check compiled.isOk
    check compiled.value.sql == "SELECT * FROM \"users\" WHERE \"active\" = ? AND (\"role\" = ? OR \"role\" = ?)"
    check compiled.value.params.len == 3

  test "compiles GROUP BY and HAVING after WHERE":
    var db: Db
    let compiled = db.table("events")
      .select("kind")
      .where("active", "=", true)
      .groupBy("kind")
      .having("kind", "!=", "ignored")
      .orderBy("kind")
      .compile()
    check compiled.isOk
    check compiled.value.sql == "SELECT \"kind\" FROM \"events\" WHERE \"active\" = ? GROUP BY \"kind\" HAVING \"kind\" != ? ORDER BY \"kind\" ASC"
    check compiled.value.params.len == 2
    check not db.table("events").having("kind", "=", "x").compile().isOk
