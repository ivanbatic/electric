import { GestureHandlerRootView } from 'react-native-gesture-handler';
import { Stack } from 'expo-router';

export default function AppLayout() {
  return (
    <Stack screenOptions={{
      headerBackTitleVisible: false,
      contentStyle: {
        padding: 16,
        
      }
    }}>
      <Stack.Screen
        name="(home)"
        options={{
          headerShown: false,
          contentStyle: {
            padding: 0
          }
        }}
      />

      <Stack.Screen
        name="shopping_list/[shopping_list_id]/index"
        options={{
          contentStyle: {
            paddingHorizontal: 16
          }
        }}
      />

      <Stack.Screen
        name="shopping_list/add"
        options={{
          title: 'Create shopping list',
          presentation: 'card',
        }}
      />
      <Stack.Screen
        name="shopping_list/[shopping_list_id]/edit"
        options={{
          title: 'Edit shopping list',
          presentation: 'formSheet',
        }}
      />
      <Stack.Screen
        name="shopping_list/[shopping_list_id]/item/add"
        options={{
          title: 'Add shopping list item',
          presentation: 'formSheet',
        }}
      />
      <Stack.Screen
        name="family/[family_id]/edit"
        options={{
          headerTitle: 'Edit family',
          presentation: 'formSheet',
        }}
      />
      <Stack.Screen
        name="family/[family_id]/member/[member_id]/edit"
        options={{
          headerTitle: 'Edit member',
          presentation: 'formSheet',
        }}
      />
    </Stack>
  );
}