#include "../audit_error.h"
#include<iostream>
int main()
{
    //simulate a succesful operation 
     AuditResult success = {
        AuditError::None,
        ""
    };
    // simulate a problem at opening the file 
    AuditResult failure= {
        AuditError:: open_Failed, 
        " The audit log cannot be opened"

    };
    if(success.ok())
    {
        std::cout<<"First operation was succesful\n";
    }
    if(!failure.ok())
    {
        std::cout<<"Second operation is failed\n ";
        std::cout << "Reason: " << failure.message << '\n';
    }
    return 0;

}