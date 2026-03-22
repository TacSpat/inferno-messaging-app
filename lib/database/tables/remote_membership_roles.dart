import 'package:drift/drift.dart';

class RemoteMembershipRoles extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get remoteMemberId => integer()();
  IntColumn get roleId => integer()();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {remoteMemberId, roleId},
  ];
}
