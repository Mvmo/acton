#include "../builtin.h"

int main() {
  $register_builtin();
  $str str1 = from$UTF8("A plain ASCII string 123,.%");
  $str str2 = from$UTF8("Some non-ASCII öé");
  $str str3 = from$UTF8("And some very non-ASCII: 围绕疫情我们有过不和谐的声音");
  $list lst = $list_fromiter(NULL);
  $list_append(lst,str1);
  $list_append(lst,str2);
  $list_append(lst,str3);
  $serialize_file(($Serializable)lst,"test3.bin");
  $list lst2 = ($list)$deserialize_file("test3.bin");
  for (long i = 0; i < $list_len(lst2); i++) 
    printf("%s\n",to$UTF8($list_getitem(lst2,i)));
}