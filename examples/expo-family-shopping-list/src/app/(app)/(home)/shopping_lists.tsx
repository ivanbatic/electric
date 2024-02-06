import { useLiveQuery } from 'electric-sql/react'
import React, { useMemo } from 'react'
import { FlatList, SafeAreaView, View } from 'react-native'
import { List, FAB, Text } from 'react-native-paper'
import { useElectric } from '../../../components/ElectricProvider'
import ShoppingListCard from '../../../components/ShoppingListCard'
import { Link } from 'expo-router'
import FlatListSeparator from '../../../components/FlatListSeparator'
import { useAuthenticatedUser } from '../../../components/AuthProvider'

export default function ShoppingLists () {
  const userId = useAuthenticatedUser()!
  const { db } = useElectric()!
  const { results: memberships = [] } = useLiveQuery(db.member.liveMany({
    include: {
      family: {
        include: {
          shopping_list: {
            select: {
              list_id: true,
              updated_at: true
            }
          }
        }
      }
    },
    where: {
      user_id: userId
    }
  }))

  const shoppingLists = useMemo(() => memberships.reduce(
      (allLists, membership) => [
        ...allLists,
        ...(membership.family?.shopping_list ?? [])],
      []
    ).sort((a: any, b: any) => b.updated_at.getTime() - a.updated_at.getTime()),
    [memberships]
  )


  return (
    <SafeAreaView style={{ flex: 1 }}>
      <View style={{ flex: 1, paddingHorizontal: 16 }}>
        <List.Section style={{ flex: 1 }}>
          <List.Subheader>Your Shopping Lists</List.Subheader>
          { shoppingLists.length > 0 ?
            <FlatList
            contentContainerStyle={{ padding: 6 }}
            data={shoppingLists}
            renderItem={(item) => (
              <Link href={`/shopping_list/${item.item.list_id}`} asChild>
                <ShoppingListCard shoppingListId={item.item.list_id} />
              </Link>
            )}
            ItemSeparatorComponent={() => <FlatListSeparator />}
            keyExtractor={(item) => item.list_id}
            />
            :
            <View style={{ flexDirection:'column', alignItems: 'center' }}>
              <Text variant="bodyLarge">No shopping lists</Text>
            </View>
          }
        </List.Section>
        <Link
          style={{
            position: 'absolute',
            marginRight: 16,
            marginBottom: 16,
            right: 0,
            bottom: 0,
          }}
          href="/shopping_list/add"
          asChild
        >
          <FAB icon="plus" />
        </Link>
      </View>
    </SafeAreaView>
  )
}