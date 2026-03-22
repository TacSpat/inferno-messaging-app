import 'package:drift/drift.dart';

class MembershipRoles extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get serverMembershipId => integer()();
  IntColumn get roleId => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {serverMembershipId, roleId},
  ];
}
